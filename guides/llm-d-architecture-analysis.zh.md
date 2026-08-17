# llm-d 架构分析：KV Cache 探测与 EPP 路由交互

> 本文分析 llm-d 如何探测模型服务器的 KV cache，以及 EPP 路由网关与模型服务器的交互方式。
>
> **注意**：本仓库（kubernetes-sigs/llm-d 的 docs 站点）不含 Go 实现代码。本文结论来自仓库内的架构文档：
> - `docs/architecture/advanced/kv-management/kv-indexer.md`
> - `docs/architecture/advanced/kv-management/prefix-cache-aware-routing.md`
> - `docs/architecture/advanced/kv-management/kv-offloader.md`
> - `docs/architecture/core/router/epp/README.md`
> - `docs/architecture/core/router/epp/datalayer.md`
> - `docs/architecture/core/router/epp/scheduling.md`
> - `docs/architecture/core/router/proxy.md`
> - `docs/architecture/core/model-servers.md`
> - `docs/architecture/advanced/autoscaling/hpa-wva.md`
> - `guides/precise-prefix-cache-routing/README.md`
> - `guides/tiered-prefix-cache/README.md`
>
> 实现代码位于 [llm-d/llm-d-router](https://github.com/llm-d/llm-d-router) 与 [llm-d/llm-d-kv-cache](https://github.com/llm-d/llm-d-kv-cache) 仓库。

---

## 1. llm-d 如何探测 KV Cache

llm-d 探测 KV cache 的**主体不是主动轮询扫描内存，而是模型服务器主动推送事件**；另有指标轮询和启发式两种辅助机制，共三层。

### 1.1 精确探测：事件驱动（KV-Cache Indexer，核心机制）

**模型服务器侧 —— KV 事件发布**（`guides/precise-prefix-cache-routing/README.md:309`）

每个 vLLM/SGLang pod 启动时带事件发布配置：

```bash
--kv-events-config '{"publisher":"zmq","endpoint":"$(KV_EVENTS_ENDPOINT)","topic":"kv@$(POD_IP):$(POD_PORT)@<model>"}'
```

KV cache 状态每次变化（block 分配/淘汰）就主动发一条 ZMQ 消息。事件类型有三种（`docs/architecture/advanced/kv-management/kv-indexer.md:59-63`）：

| 事件 | 含义 | 关键 payload |
|---|---|---|
| `BlockStored` | 某 device tier 上新创建了 block | 内容哈希链、父哈希、token chunk、LoRA ID/name、多模态 extra_keys |
| `BlockRemoved` | block 被淘汰 | block 哈希、tier / attention group |
| `AllBlocksCleared` | 整个 cache 被清空（如 RL 权重 rollout） | —（indexer 删除该 pod 全部条目） |

**EPP 侧 —— KV-Cache Indexer 订阅并建索引**（`kv-indexer.md:23-53`）

llm-d Router 内的 EPP 通过 ZMQ 订阅事件，维护 `block key → pods` 映射。两种事件投递模式：

- **Centralized**：EPP bind `tcp://*:5557`，所有模型服务器 pod 作为 PUB 连上来（适合单 EPP 副本）。

```
  Model Server A ──► ZMQ ──┐
  Model Server B ──► ZMQ ──┼──► EPP (binds tcp://*:5557)
  Model Server C ──► ZMQ ──┘
```

- **Pod discovery**：每个 pod 自己 bind `:5556`，EPP 通过 k8s label selector 发现 pod 并为每个建立订阅（适合 active-active 多 EPP，各副本独立收敛到同一索引）。

```
  EPP Replica 1 ──ZMQ──┐
                       ├──► Model Server A (binds :5556)
  EPP Replica 2 ──ZMQ──┤
                       ├──► Model Server B (binds :5556)
  EPP Replica 1 ──ZMQ──┤
                       └──► Model Server C (binds :5556)
  EPP Replica 2 ──ZMQ──┘
```

索引后端（`kv-indexer.md:89-102`）：

| 后端 | 存储 | 适用场景 | 权衡 |
|---|---|---|---|
| In-Memory（默认） | 两级 LRU：外层按 block hash、内层按 pod | 大多数部署 | 延迟最低；条目数固定（默认 100M key × 10 pod），规模可预测 |
| Cost-Aware Memory | Ristretto cache，按成本准入/淘汰 | 每条目大小差异大（多模态、变长 LoRA 元数据） | 按字节设预算（如 2GiB）；压力下可能概率性拒收 |
| Redis / Valkey | 外部 TCP 服务 | 需要持久/超长存活的索引（少见） | 每次查找多一跳网络；一般没有必要 |

**路由时如何用**（`kv-indexer.md:104-135`）

1. `token-producer` 插件调用 vLLM 的 render HTTP 端点（`/v1/completions/render`、`/v1/chat/completions/render`，默认指向 `http://localhost:8000`）做**精确 tokenize**。该端点由 `vllm serve <model>` 或 GPU-less 的 `vllm launch render <model>` 提供，通常部署为 EPP pod 内的 sidecar（loopback）或共享 render Service。旧的 gRPC-over-UDS tokenizer sidecar 已废弃。
2. 把 token 序列切成 block 并计算哈希链，与 vLLM 发的 block key 同构。
3. `prefix-cache-scorer` 查索引，对每个候选 pod 计算**最长连续前缀**匹配的 block 数——注意力是因果的，block i 依赖 0..i-1 整条链，链在中间断了则后面的命中也不计分：

```
Block keys:   B0    B1    B2    B3    B4

Pod A:        yes   yes   yes   yes   no    → score = 4 blocks
Pod B:        yes   yes   no    -     -     → score = 2 blocks（链在 B2 处断）
Pod C:        no    -     -     -     -     → score = 0（无前缀）
```

跨 tier 命中的 block 按 tier 加权（默认 `gpu = 1.0`、`cpu = 0.8`），同一 block 多 tier 同时存在时取最大权重。原始分归一化到 `[0.0, 1.0]` 后进入 EPP 标准 Filter-Score-Pick 流水线，与其他 scorer（队列深度、KV cache 利用率等）加权合成。

**Speculative indexing**（`kv-indexer.md:137-143`）：路由决策到 `BlockStored` 确认事件到达之间有窗口期，背靠背同前缀请求可能还没等到事件就来了。开启后（生产推荐 `speculativeIndexing: true`），路由决策刚做完就往索引插入短寿命预测条目（默认 TTL 2s），等确认事件到达或过期。

**多模态 / LoRA / 混合注意力**（`kv-indexer.md:145-151`）：

- 多模态：图像/音频内容哈希通过 `BlockStored` 事件的 `extra_keys` 字段折叠进 block key 链；读侧通过对 tokenize 后 prompt 中的多模态占位符重新计算。文本相同但图片不同的 prompt 哈希不同、独立路由。
- LoRA：`BlockStored` 带 `LoraName` 时用它替代 base model name 参与 key 派生，不同 adapter 产生不同 key 链。
- 混合注意力（hybrid attention，设计中）：full/sliding-window/linear 层组独立淘汰，需按窗口大小把前缀命中分类为 full/partial/miss。

### 1.2 近似探测：启发式本地索引（轻量方案）

（`docs/architecture/advanced/kv-management/prefix-cache-aware-routing.md:9-29`）

- 无 tokenizer、无 ZMQ：按**字符→token 比例**近似分块（如 16 token ≈ N 字符），构建滚动哈希链。
- EPP 维护本地 LRU 索引，记录"哪些前缀哈希最近被路由到哪些 pod"，**假设路由过去后该 pod 就有缓存**（学习式）。
- 优点：零外部依赖。缺点：pod 因内存压力淘汰前缀时 EPP 不知道，索引会发散。

### 1.3 指标探测：Prometheus 轮询（用于负载均衡/扩缩容）

（`docs/architecture/core/model-servers.md:42-44`）

这是真正的"轮询"路径，目的不是定位某个 block 在哪个 pod，而是感知缓存压力：

| 用途 | vLLM | SGLang | TRT-LLM |
|---|---|---|---|
| KV cache 利用率 | `vllm:kv_cache_usage_perc` | `sglang:token_usage` | `trtllm_kv_cache_utilization` |
| block size / 总 block 数 | `vllm:cache_config_info`（label `block_size` / `num_gpu_blocks`） | `sglang:cache_config_info`（`page_size`） | `trtllm_kv_cache_max_blocks` |

消费者有两处：

- `kv-cache-utilization-scorer`：偏向利用率低的 pod，避免碎片化（`docs/architecture/core/router/epp/scheduling.md:89`）。
- WVA autoscaler 饱和度分析器：KV cache 利用率 ≥ 阈值（默认 0.80）判饱和触发扩容；PromQL 如 `max by (pod) (max_over_time(vllm:kv_cache_usage_perc[1m]))`（`docs/architecture/advanced/autoscaling/hpa-wva.md:67,184`）。

### 1.4 KV Offloading：探测之外的容量层

（`docs/architecture/advanced/kv-management/kv-offloader.md`）

容量层，扩展 cache 到 HBM 之外，与探测机制正交但配合工作：

- **原生路径**：vLLM 内置 `OffloadingConnector`，把 block 异步搬到 CPU RAM（DMA 传输）或经 llm-d FS backend 落到共享文件系统。
- **外接 connector**：LMCache / Mooncake / NVIDIA KVBM 等第三方 cache 引擎，通过 vLLM V1 Connector API / SGLang HiCache / TRT-LLM KV Cache Connector API 接入，自带索引、内存管理、存储。

块跨 tier 存放时，精确探测依然有效——KV 事件带 tier 信息，scorer 按 tier 加权计分。

---

## 2. EPP 路由网关与 Model Server 的交互

**核心结论：EPP 与 model server 在请求路径上没有任何直接连接——EPP 是"旁路参谋"，真正把流量发给 model server 的是 proxy（Envoy 等）。** 交互分三条通道：

### 2.1 请求路径：ext-proc 协议（间接交互）

（`docs/architecture/core/router/epp/README.md:11-41`、`docs/architecture/core/router/proxy.md:16-25`）

```
Client → Proxy (Gateway) ──ext-proc gRPC──> EPP
                                 │ 返回选中的 pod 地址 (IP:port)
                                 ▼
                          Proxy ──HTTP/gRPC 直连──> Model Server Pod
```

逐步流程：

1. 请求到达 proxy（Gateway），proxy 的 ext-proc filter 通过 **Envoy External Processing 协议**调用 EPP，把**请求头和 body 整体传给 EPP**。唯一支持的 body mode 是 `FULL_DUPLEX_STREAMED`。
2. EPP 的 Request Handler 把请求解析成内部结构（自带 OpenAI HTTP 和 vLLM gRPC 两种 parser，可自定义），随后走 Flow Control（准入控制、优先级排队、公平性）和 Request Scheduler 的 **Filter → Score → Pick** 插件流水线选出最优 pod。
3. EPP 按 [Endpoint Picking Protocol](https://github.com/kubernetes-sigs/gateway-api-inference-extension/tree/main/docs/proposals/004-endpoint-picker-protocol) 把**选中的 endpoint 地址返回给 proxy**。EPP 返回的只是地址，**不代理任何数据流量**。
4. Proxy 把请求直接转发给该 model server pod（OpenAI 兼容 HTTP `:8000` 或 vLLM gRPC 端口）。
5. 响应流回 proxy 时**再次经过 ext-proc 进入 EPP 做后处理**（统计、记账等），然后返回客户端。

部署形态（`proxy.md:29-111`）：

- **Standalone**：proxy 作为 sidecar 与 EPP 同 pod，ext-proc 走 localhost，无需 Gateway API（适合测试、批处理、RL 流水线）。
- **Gateway Mode（Inference Gateway）**：基于 [Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/)，HTTPRoute 把 `InferencePool` 作为 backend；请求命中 InferencePool 时被"park"，咨询该 pool 对应的 EPP 后再放行（支持 Istio / GKE Gateway / agentgateway / Envoy AI Gateway）。

### 2.2 状态采集：EPP 与 model server 的直接交互（异步，数据层）

（`docs/architecture/core/router/epp/datalayer.md`）

数据层遵循 Source → Extract → Attribute 生命周期，把外部数据归一到 Endpoint 属性上。这是 EPP 与 model server 之间**仅有的直接交互**：

| 方式 | 谁发起 | 内容 | 用途 |
|---|---|---|---|
| **Metrics 轮询** | EPP 主动 | `metrics-data-source` 按配置间隔轮询 model server 的 Prometheus 兼容 metrics 端点（每个 endpoint 一个 Collector，不强制经 Prometheus 中转）；`core-metrics-extractor` 把各引擎指标名（`vllm:kv_cache_usage_perc`、`sglang:token_usage` 等）映射成标准 attribute（`KVCacheUsagePercent`、`WaitingQueueSize`） | queue-depth-scorer、kv-cache-utilization-scorer、Flow Control 饱和度检测 |
| **KV 事件订阅** | model server 主动推 | ZMQ `BlockStored` / `BlockRemoved` / `AllBlocksCleared`（见 §1.1） | KV-Cache Indexer → 精确前缀缓存路由 |
| **Consultant sidecar** | EPP 主动调 | token-producer 调 vLLM render 端点做精确 tokenize（EPP pod 内 `vllm launch render` 的 GPU-less sidecar）；latency predictor 等 | 精确前缀匹配的前置步骤 |

### 2.3 端点发现：不经过 model server

EPP 的 Data Layer watch **Kubernetes API**（InferencePool、Pods），pod 地址（IP:port）来自 K8s 而非模型服务器注册；pod 生命周期变化（Add/Update/Delete）由 `endpoint-notification-source` 通知 extractor 做初始化/清理（如建/删该 pod 的 metrics collector 和 ZMQ 订阅）。

推论（`guides/precise-prefix-cache-routing/README.md:124`）：render pod 不能带 `llm-d.ai/guide` label——该 label 是 InferencePool / model server 的选择器，否则 EPP 会把 render pod 当可路由的 model server 并尝试订阅它不存在的 KV-event socket。

### 2.4 特殊交互：P/D 分离时一次调度返回两个端点

（`docs/architecture/core/router/epp/scheduling.md:147`）

prefill/decode 分离时，ProfileHandler 同时选出 prefill 和 decode 端点：**decode 端点作为主目标返回给 proxy**，**prefill 端点通过特殊 header 注入请求**；请求到达 decode worker 后，其旁的 sidecar 拦截请求、从 header 提取 prefill 端点地址、在解码开始前协调 remote prefill。

---

## 3. 总结

```
                      ┌─────────────────────────────────────────────┐
                      │                  EPP (llm-d Router)          │
                      │  Request Handler → Flow Control → Scheduler  │
                      │  (Filter → Score → Pick)                    │
                      │                                             │
                      │  Data Layer:                                │
                      │   ├─ K8s API watch（端点发现）              │
                      │   ├─ metrics 轮询（利用率/队列）            │
                      │   ├─ ZMQ 订阅 KV 事件（block → pods 索引）  │
                      │   └─ consultant sidecars（tokenizer 等）    │
                      └──────┬──────────────▲──────────────┬────────┘
                             │ ext-proc     │              │
                             │ (地址建议)    │ 响应后处理    │ 异步感知
          ┌──────────────────▼──────┐       │              │
          │   Proxy / Gateway        │───────┘              │
          │   (Envoy 等, ext-proc)   │                      │
          └──────────┬───────────────┘                      │
                     │ 请求直接转发                          ▼
                     ▼                            ┌─────────────────┐
              ┌─────────────────┐   KV 事件(ZMQ)  │  Model Server   │
              │  Model Server   │────────────────►│  (vLLM/SGLang)  │
              │  Pod (IP:port)  │  metrics 轮询    │  KV cache       │
              └─────────────────┘◄────────────────┴─────────────────┘
```

**一句话总结**：

1. **KV cache 探测**：push 模型——vLLM/SGLang 通过 `--kv-events-config` 把 KV cache 变化（BlockStored/BlockRemoved/AllBlocksCleared）以 ZMQ 事件推给 EPP 的 KV-Cache Indexer，indexer 建 `block key → pods` 索引；请求到达时经 vLLM render 端点精确 tokenize 后查索引、按最长连续前缀打分。辅助机制：启发式本地索引（近似）、Prometheus 指标轮询（压力感知）。
2. **EPP 与 model server 交互**：请求数据面是 Proxy → Model Server 直连，EPP 只通过 ext-proc 被 proxy 咨询并返回选路结果；EPP 与 model server 的直接交互全是异步"感知"通道（metrics 轮询、ZMQ KV 事件、render 端点 tokenize）；pod 地址来自 K8s API。
