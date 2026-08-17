# 沐曦 GLM-5.1-W8A8 PD 分离压测报告

> 日期：2026-08-13
> 范围：验证 llm-d EPP Router 对沐曦（MetaX）GPU 上 SGLang PD 分离的支持，并打通原生 `/generate` 压测链路
> 结论：✅ 两条压测链路全部验证通过（EPP → OpenAI 协议；sglang gateway → 原生协议）

---

## 1. 测试目标

1. 验证 llm-d EPP Router 能对沐曦 GPU 上的 SGLang prefill/decode 分离集群正确调度（透明 PD）。
2. 解决 `bench_serving --backend=sglang --pd-separated` 经 EPP 压测时的 400 报错。
3. 打通 sglang 原生 `/generate` 协议的压测链路（sglang 自带 gateway）。

## 2. 环境拓扑

| 组件 | 命名空间 | Pod / 位置 | IP / 端口 | 说明 |
|------|---------|-----------|-----------|------|
| llm-d Router (EPP) | metax-ai-pd | pd-disaggregation-epp-* | 10.0.0.232:8081（hostNetwork, node mxgpu-1-232） | Envoy + EPP（`ghcr.io/llm-d/llm-d-router-endpoint-picker:v0.9.0`），ClusterIP svc: 9002(ext-proc)/9090/80→8081 |
| Prefill ×4 | metax-ai-pd | prefill-0 / -0-1 / -0-2 / -0-3 | 10.0.0.147 / 10.0.0.165 / 10.0.0.154 / 10.0.0.152，modelserver **:8000**（hostNetwork） | **1 个 LWS 4 节点逻辑实例**（NNODES=4，PP=4 × TP=8，共 32 卡，启动命令 `prefill.sh glm-5.sh 10.0.0.147 4 <rank>`）；**仅 master prefill-0（147）是有效入口**，worker 的 8000 为残接口（`/server_info` 404） |
| Decode ×4 | metax-ai-pd | decode-0 / -0-1 / -0-2 / -0-3 | 10.0.0.168 / 10.0.0.166 / 10.0.0.167 / 10.0.0.169 | **1 个 LWS 4 节点逻辑实例**（TP=32, DP=32, EP=32）；**仅 master decode-0（168）是有效入口**：modelserver **:8200**，routing-proxy sidecar **:8000**（kv-connector=sglang） |
| 压测 Pod | default | sglang-pd-stress-test | Pod IP **10.0.1.168**（node mxgpu-1-232） | 镜像 `harbor.mycompany.com/metax/sglang:glmpd`；sglang v0.5.12（mcoplib 0.4.7, MACA 3.7.1.13.dsv4） |
| 模型 | — | /workspace/data/GLM-5.1-W8A8 | served_model_name 即模型路径 | GLM-5.1 W8A8 量化（推理模型，chat 输出 reasoning_content） |

**关键端口约定（config.sh 已对齐 llm-d）：**

```
prefill  modelserver : 8000
decode   modelserver : 8200
decode   sidecar     : 8000（EPP 请求入口）
gateway  (压测pod内)  : 8001
```

## 3. 问题与根因：`/generate` 被 EPP 拒绝

### 3.1 现象

```
ValueError: Warmup failed - Please make sure benchmark arguments are correctly specified.
Error: Bad Request: inference error: BadRequest - no parser registered matching path suffix for: /generate
```

### 3.2 根因（EPP 日志铁证）

llm-d Router 的 EPP 按**路径后缀**匹配请求体 parser（`llm-d-router/pkg/epp/handlers/server.go:198`，`StreamingServer.getOrResolveParser`）。parser 注册表只内置 OpenAI 兼容端点（`/v1/chat/completions`、`/v1/completions`、`/v1/models` 等），**没有 sglang 原生 `/generate` 的 parser**，直接返回 400：

```
{"level":"error","caller":"handlers/server.go:198","msg":"Error resolving parser for path",
 "path":"/generate","error":"no parser registered matching path suffix for: /generate"}
```

### 3.3 为什么不能"配置"让 EPP 支持 /generate

- EPP 没有路径映射 / context root 配置项，parser 注册表是内置的（v0.9.0）。
- Helm chart 自带 `payload-agnostic.yaml`（`passthrough-parser`，不解析 body），但启用它会：① 丢失 PD disagg 插件链（`always-disagg-pd-decider`/prefill/decode-filter），PD 调度失效；② 原生 `/generate` 请求体无 `model` 字段，EPP 无法解析模型名选 InferencePool；③ sidecar→prefill 链路按 OpenAI 协议设计。**不适用于本场景。**
- 解码实例直连 `/generate` 也不可行：decode 以 `--disaggregation-mode=decode` 运行，要求请求携带 bootstrap room id（实测返回 `Disaggregated request received without bootstrap room id`）。bootstrap 协商必须由 sglang gateway/router 完成。

**结论：EPP 走 OpenAI 协议（透明 PD），sglang 原生协议走 sglang 自己的 gateway。两者各司其职，均为预期行为，不是配置缺陷。**

## 4. 方案一：经 EPP 压测（OpenAI 协议，透明 PD）✅

llm-d 的 PD 分离由 EPP 插件链 + routing-proxy sidecar + NIXL KV 传输在网关层透明完成，客户端只需发标准 OpenAI 请求。

### 4.1 验证命令（小规模）

```bash
cd /workspace
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
python3 -m sglang.bench_serving \
    --backend=sglang-oai-chat \
    --base-url=http://10.0.0.232:8081 \
    --dataset-name=random \
    --dataset-path=/workspace/data/ShareGPT_V3_unfiltered_cleaned_split.json \
    --tokenizer=/workspace/data/GLM-5.1-W8A8 \
    --model=/workspace/data/GLM-5.1-W8A8 \
    --num-prompts=5 \
    --max-concurrency=1 \
    --random-input=4096 \
    --random-output=512 \
    --random-range-ratio=1.0 \
    --request-rate=1.0
```

### 4.2 结果（5 × 4096in/512out, concurrency=1, rate=1.0）

| 指标 | 数值 |
|------|------|
| 成功率 | 5/5 |
| Mean E2E | 21.2 s |
| Mean TTFT | 1.11 s |
| Mean TPOT | 39.3 ms |
| Mean ITL | 86.7 ms |
| 输出吞吐 | 24.1 tok/s |

### 4.3 注意事项（实测踩坑）

1. `--backend=sglang-oai-chat` → `/v1/chat/completions`；`--backend=sglang-oai`（或 `openai`）→ `/v1/completions`。本版本 bench_serving 中两者都走 EPP 支持的 OpenAI 端点。
2. **`--base-url` 不能带 `/v1` 后缀**，否则 ready check 拼成 `/v1/v1/models` 失败。
3. `--pd-separated` 在本 Metax fork 的 bench_serving 中只作用于 `--profile` 的 profiler 启停（配合 `--profile-prefill-url`/`--profile-decode-url`），对普通压测请求无效果；经 EPP 压测时无需该参数。
4. 显式传 `--model`（后端 sglang 未设 `--served-model-name`，默认即模型路径，需一致）。
5. EPP 日志中的 `Request latency values are invalid for TPOT calculation` 为小请求下的指标计算 warning，不影响功能。

## 5. 方案二：经 sglang gateway 压测（原生 /generate + pd-separated）✅

gateway 脚本位于压测 Pod 内：`/workspace/llm-launch/sglang/`（`gateway.sh` + `config.sh` + `common.sh`）。实际启动的是 Rust 版 `sglang::router`（smg），负责 bootstrap 协商与 P/D 路由。

### 5.1 端口配置（config.sh 修改记录）

```bash
sed -i 's/^readonly prefill_server_port=.*/readonly prefill_server_port="8000"/;
        s/^readonly decode_server_port=.*/readonly decode_server_port="8200"/' \
    /workspace/llm-launch/sglang/config.sh
# gateway_server_port="8001" 保持不变
```

### 5.2 启动 gateway

```bash
cd /workspace/llm-launch/sglang
export PATH=/opt/conda/bin:$PATH
setsid bash gateway.sh prefill 10.0.0.147 decode 10.0.0.168 \
    > /workspace/gateway.log 2>&1 < /dev/null &
```

- **prefill 和 decode 各是 1 个 4 节点逻辑实例**（prefill: PP=4×TP=8；decode: TP=32/DP=32/EP=32），worker pod 的 8000 只是残接口（`/server_info` 返回 404），**主节点（worker-index=0）是唯一有效入口**。注册主节点即覆盖全部 32 卡算力，无闲置资源。
- 若需扩容 gateway 的均衡池：部署多组 LWS 逻辑实例（如 2 组 prefill），再注册各组 master IP：
  ```bash
  setsid bash gateway.sh prefill <prefill-master-1> <prefill-master-2> decode <decode-master> ...
  ```
- 重启方式：`pkill -f sglang::router` 后按上述命令重新启动。
- 日志要点：2 个 worker 注册成功；`conflicting tp_size: prefill=8, decode=32` 为预期（prefill 单机 / decode 32 卡）。

### 5.3 冒烟验证

```bash
curl -s http://10.0.1.168:8001/v1/models
curl -s -X POST http://10.0.1.168:8001/generate \
    -H 'Content-Type: application/json' \
    -d '{"text":"hello","sampling_params":{"max_new_tokens":8}}'
# → 1.2s 返回 8 tokens，bootstrap 协商由 gateway 完成
```

### 5.4 完整压测命令（50 prompts）

```bash
cd /workspace
export HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1
python3 -m sglang.bench_serving \
    --host=10.0.1.168 \
    --port=8001 \
    --backend=sglang \
    --dataset-name=random \
    --dataset-path=/workspace/data/ShareGPT_V3_unfiltered_cleaned_split.json \
    --tokenizer=/workspace/data/GLM-5.1-W8A8 \
    --num-prompts=50 \
    --max-concurrency=1 \
    --random-input=4096 \
    --random-output=2048 \
    --random-range-ratio=1.0 \
    --pd-separated \
    --request-rate=1.0
```

> 与原命令唯一区别：`--host`/`--port` 从 EPP（10.0.0.232:8081）换成 gateway（10.0.1.168:8001）。
> 50×2048 输出在 concurrency=1 / rate=1 下预计运行 50–60 分钟。

### 5.5 小规模验证结果（5 × 4096in/512out, concurrency=1）

| 指标 | 数值 |
|------|------|
| 成功率 | 5/5 |
| Mean E2E | 17.1 s |
| Mean TTFT | 0.94 s |
| Mean TPOT | 31.5 ms |
| Mean ITL | 31.5 ms |
| 输出吞吐 | 30.0 tok/s |

## 6. 性能对比（同参数 5 × 4096in/512out, concurrency=1）

| 指标 | EPP（sglang-oai-chat，触发 reasoning） | EPP（sglang-oai，completions） | sglang gateway（原生 /generate） |
|------|----------------------------------------|-------------------------------|----------------------------------|
| 成功率 | 5/5 | 5/5 | 5/5 |
| Mean E2E | 21.2 s | **16.9 s** | **17.1 s** |
| Mean TTFT | 1.11 s | 0.86 s | 0.94 s |
| Mean TPOT | 39.3 ms | **31.4 ms** | **31.5 ms** |
| 输出吞吐 | 24.1 tok/s | **30.2 tok/s** | **30.0 tok/s** |
| Mean ITL | 86.7 ms | 86.6 ms | 31.5 ms |

**公平结论（同协议对比）：EPP 网关开销 ≈ 0。** completions 模式经 EPP 与原生 gateway 的 E2E/TPOT/吞吐几乎完全一致（16.9s vs 17.1s、31.4 vs 31.5 ms、30.2 vs 30.0 tok/s）。

此前 20% 差距的来源：

1. **chat 模板触发 GLM-5.1 reasoning 模式**：sglang-oai-chat 路径实测输出 100% reasoning token（16/16），每 token 成本更高；completions / 原生路径 `reasoning_tokens: 0`。这是模型行为，不是网关开销。
2. **ITL 口径差异**：EPP/Envoy 按 SSE chunk 转发（多 token 打包），ITL 记录的是块间隔（86ms）；原生路径逐 token 推送（ITL≈TPOT≈31.5ms）。TPOT 与 E2E 不受影响——对"每 token 延迟"敏感的业务以 TPOT/E2E 为准。

## 7. EPP 核心优势与选型参考

### 7.1 核心优势

1. **Kubernetes 原生端点发现（vs 手工 IP 注册）**

   - EPP 通过 InferencePool CRD + 标准 LabelSelector 发现端点——pod 扩缩容、重启、节点漂移自动感知，EndpointSlice 驱动。
   - 你们的 sglang gateway 需要 `gateway.sh prefill <IP> decode <IP>` 手工注册，节点漂移后要人工改配置重启。这正是你们当时为什么把 InferencePool selector 设为 `worker-index=0` 的原因——交给 K8s 选，而不是写死 IP。

2. **多模型 / 多租户统一入口**

   - EPP 按请求里的 `model` 字段路由到不同 InferencePool。你们 EPP 日志里的 `modelName → targetModelName` 映射就是证据：同一网关入口 10.0.0.232:8081 可以同时服务 glm-5.1-w8a8、deepseek-r1 等多个模型池。
   - smg 当前配置是单后端单模型，多模型就得起多个 gateway 进程 + 外层再加一层分发。

3. **调度策略插件化（可组合、可扩展）**

   - 你们的 pd-config.yaml 就是活例子：always-disagg-pd-decider + prefill-filter/decode-filter + 4 个 scorer 按权重打分。要改策略（加 session-affinity、按租户、按前缀缓存命中率加权）就是改 YAML，不用改代码。
   - smg 的 cache_aware 等策略是内置的，定制空间有限。

4. **与 K8s 网关生态协同（流量治理一体）**

   - EPP 以 Envoy ext-proc 方式工作，和 Gateway API/HTTPRoute、Istio、kgateway 同层组合：鉴权、限流、TLS、灰度、超时等 L7 治理与推理调度在同一个入口完成。
   - 原生 gateway 是独立进程，这些都要自己另搭。

5. **后端与硬件异构**

   - llm-d 支持 vLLM/SGLang × NVIDIA/AMD/TPU/XPU/Metax——你们这套 metax overlay 本身就是把它扩展到沐曦的证明。未来混部（比如部分流量走 vLLM、部分走 SGLang）在同一 EPP 下统一调度。
   - smg 只服务 sglang 生态。

6. **开箱即用的推理指标**

   - EPP 直接产出 TTFT/TPOT/E2E 等推理延迟指标（我们日志里见过 RecordRequestTPOT），配 Prometheus 即可监控；路由决策（modelName/targetModelName）可审计。

### 7.2 什么时候原生 gateway 更合适

| 场景 | 选型 |
|------|------|
| 压测 sglang 本身 / 需要原生 /generate、bootstrap 控制、pd-separated profiling | sglang gateway |
| 生产服务：多模型、多租户、自动扩缩容、K8s 生态集成 | llm-d EPP |
| 纯 sglang、静态拓扑、追求最简链路 | sglang gateway 够用 |

> 一句话总结：EPP 买的是"生产化平台"——端点自动发现、多模型路由、可编程调度、与 K8s 网关集成；原生 gateway 买的是"贴近引擎的控制力"。你们现在验证的正是：两者在沐曦 PD 分离上都能工作，且同协议下性能无差异（EPP 开销 ≈0），所以选型可以纯粹按场景来。

## 8. 关键结论

1. **llm-d EPP 支持沐曦 PD 分离**：以 OpenAI 兼容协议经 EPP 压测，PD 调度（EPP 选端 → sidecar → prefill → NIXL KV → decode）全链路验证通过，5/5 成功。
2. **EPP 不支持原生 `/generate`**：parser 注册表仅含 OpenAI 端点，无路径映射配置，属设计行为。原生协议请走 sglang gateway。
3. **sglang gateway 已打通**：config.sh 端口对齐 llm-d（prefill=8000 / decode=8200），注册主节点 IP 后，`--backend=sglang --pd-separated` 原生压测 5/5 成功。
4. **decode 实例不可直连**：PD 模式要求 bootstrap room id，直连 `/generate` 会报 `Disaggregated request received without bootstrap room id`，必须经 gateway（或 EPP→sidecar 链路）。
5. **EPP 与原生 sglang 同协议性能持平**：completions 模式 E2E 16.9s / TPOT 31.4ms ≈ 原生 17.1s / 31.5ms。压测 llm-d 整链路建议用 `--backend=sglang-oai`（completions），避免 chat 模板引入 reasoning token 干扰对比。
6. **负载均衡说明**：EPP 本身支持 P/D 负载均衡（prefill/decode-filter + queue-scorer / kv-cache-utilization-scorer / prefix-cache-scorer / active-request-scorer 打分），gateway（smg）使用 cache_aware 策略。但当前拓扑为 1 个逻辑 prefill + 1 个逻辑 decode（各 4 节点 32 卡，主节点唯一入口），候选池各只有 1 个端点，无均衡空间；横向扩展多组 LWS 逻辑实例后，两端都会自动按打分/策略均衡。

## 9. 附录：常用排查命令

```bash
# 拓扑
kubectl get pods -n metax-ai-pd -o wide

# EPP 日志（路由决策 / parser 错误）
kubectl logs -n metax-ai-pd pd-disaggregation-epp-788c98b4b9-5xx6g -c epp --tail 50

# decode sidecar 日志
kubectl logs -n metax-ai-pd decode-0 -c routing-proxy --tail 20

# prefill 推理日志（确认 Prefill batch 发生）
kubectl logs -n metax-ai-pd prefill-0 -c modelserver --tail 10

# gateway 进程与日志（压测 Pod 内）
ps aux | grep sglang::router
tail -f /workspace/gateway.log
```
