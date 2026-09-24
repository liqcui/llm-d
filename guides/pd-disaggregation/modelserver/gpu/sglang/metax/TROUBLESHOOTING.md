# 沐曦 (MetaX) GPU PD 分离 — 排障记录

## 1. Calico CNI RBAC 权限不足导致 EPP Pod 无法启动

### 现象

```bash
kubectl -n metax-ai-pd get pod -l llm-d-router-gateway=pd-disaggregation-epp
# NAME                                     READY   STATUS    RESTARTS   AGE
# pd-disaggregation-epp-xxxxxxxxxx-xxxxx   0/2     Pending   0          ...
```

`kubectl describe pod` 显示 `FailedCreatePodSandBox` 错误，Calico CNI 插件报权限不足。

### 根因

集群 Calico 安装时创建的 `calico-cni-plugin` ClusterRole 权限严重不足。原始权限仅包含：

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods", "nodes"]
    verbs: ["get"]
  - apiGroups: ["crd.projectcalico.org"]
    resources: ["clusterinformations"]
    verbs: ["get"]
```

Calico CNI 插件在创建 pod sandbox 时需要读取/修改多种 Kubernetes 资源和 Calico CRD，逐一暴露的错误包括：

| 错误阶段 | 缺少的权限 |
|---------|-----------|
| 1 | `get clusterinformations.crd.projectcalico.org` (cluster scope) |
| 2 | `get namespaces` (cluster scope) |
| 3 | `list ippools.crd.projectcalico.org` (cluster scope) |
| 4 | `list ipreservations.crd.projectcalico.org` (cluster scope) |
| 5 | `create blockaffinities.crd.projectcalico.org` (cluster scope) |
| 6 | `patch pods/status` (namespace scoped) |

### 修复

```bash
# 查看当前 ClusterRole
kubectl get clusterrole calico-cni-plugin -o yaml

# 补全权限
kubectl patch clusterrole calico-cni-plugin --type='json' -p='[
  {"op": "replace", "path": "/rules/0/resources",
   "value": ["pods","nodes","namespaces","endpoints","services","pods/status"]},
  {"op": "replace", "path": "/rules/0/verbs",
   "value": ["get","list","watch","patch","update"]},
  {"op": "replace", "path": "/rules/1/resources",
   "value": ["*"]},
  {"op": "replace", "path": "/rules/1/verbs",
   "value": ["get","list","watch","create","update","patch","delete"]}
]'

# 验证
kubectl get clusterrole calico-cni-plugin -o yaml
kubectl auth can-i patch pods/status \
  --as=system:serviceaccount:kube-system:calico-cni-plugin \
  -n metax-ai-pd
```

### 修复后的 ClusterRole

```yaml
rules:
  - apiGroups: [""]
    resources: ["pods","nodes","namespaces","endpoints","services","pods/status"]
    verbs: ["get","list","watch","patch","update"]
  - apiGroups: ["crd.projectcalico.org"]
    resources: ["*"]
    verbs: ["get","list","watch","create","update","patch","delete"]
```

### 影响范围

此问题影响**所有使用 pod 网络的 pod**（包括 EPP router、envoy-proxy 等）。使用 `hostNetwork: true` 的 pod（沐曦 prefill/decode）不受影响，因为它们绕过 Calico pod 网络。

---

## 2. EPP router hostNetwork 配置

### 变更

`router/pd-disaggregation.values.yaml` 增加：

```yaml
router:
  hostNetwork: true
```

### 原因

集群节点间 pod 网络（Calico）不稳定时，EPP router 使用 hostNetwork 直接绑定宿主机网络，避免 pod 网络故障影响路由。

### 生效

```bash
helm upgrade pd-disaggregation ${ROUTER_STANDALONE_CHART} \
  -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
  -f ${REPO_ROOT}/guides/pd-disaggregation/router/pd-disaggregation.values.yaml \
  -n metax-ai-pd --version ${ROUTER_CHART_VERSION}
```

---

## 3. Prefill readiness probe 路径错误

### 现象

SGLang router 报错：`No prefill workers available`

### 根因

Base recipe 的 prefill Deployment 定义的 readiness probe 使用 `/v1/models` 端点，但 **SGLang prefill 模式不提供此端点**（只提供 `/health`）。prefill pod 永远无法通过 readiness check → EPP `prefill-filter` 排除所有 prefill pod。

### 修复

`patch-prefill.yaml` 中显式覆盖所有 probe 的 `httpGet` 路径为 `/health`：

```yaml
startupProbe:
  httpGet:
    path: /health
    port: modelserver
  initialDelaySeconds: 30
  periodSeconds: 30
  timeoutSeconds: 5
  failureThreshold: 120
livenessProbe:
  httpGet:
    path: /health
    port: modelserver
  periodSeconds: 10
  timeoutSeconds: 5
  failureThreshold: 3
readinessProbe:
  httpGet:
    path: /health
    port: modelserver
  periodSeconds: 5
  timeoutSeconds: 2
  failureThreshold: 3
```

---

## 5. llm-d EPP 与沐曦 PD 分离集成

### 5.1 问题一：EPP/sidecar 硬编码 prefill:8000

#### 现象

- EPP 返回 `404 {"detail":"Not Found"}`
- decode sidecar 日志：`http: proxy error: dial tcp <prefill-ip>:8000: connect: connection refused`

#### 根因

llm-d Router 的 SGLang connector 和 InferencePool targetPort 默认使用 **prefill:8000**（llm-d 标准端口），而沐曦传统标准是 prefill=9292。

#### 修复：端口对齐 llm-d 规范（prefill=8000, decode=8200）

将沐曦 PD 配置的端口直接修改为 llm-d 规范端口：

| 组件 | 沐曦旧端口 | llm-d 规范端口 |
|------|-----------|---------------|
| Prefill modelserver | 9292 | **8000** |
| Decode modelserver | 9293 | **8200** |
| Decode routing-proxy sidecar | 8000 | 8000 (不变) |

涉及修改（3 种部署模式统一处理）：

- LWS: `lws/base/prefill.yaml` + `lws/base/decode.yaml` 中的 sed 端口覆盖和 containerPort
- Deployment: `patch-prefill.yaml` + `patch-decode.yaml` 中的 `--port` 和 containerPort
- StatefulSet: `multi-node/prefill-statefulset.yaml` + `decode-statefulset.yaml` + `headless-services.yaml`

**注意**：直接使用 SGLang gateway（8001）访问 PD 集群时，gateway 所在节点的 `sglang/config.sh` 需同步修改：

```bash
readonly prefill_server_port="8000"
readonly decode_server_port="8200"
```

### 5.2 问题二：decode handshake 指向 worker 节点的不存在的 bootstrap

#### 现象

```json
{"object":"error","message":"Decode handshake failed ... KVTransferError: Aborted by AbortReq","code":500}
```

decode 日志：

```
Error fetching prefill server info from bootstrap:
HTTPConnectionPool(host='10.0.0.165', port=8998): ... Connection refused
```

#### 根因

沐曦多节点 PD 中，只有 **P/D 主节点**（worker-index=0）运行 SGLang disaggregation bootstrap server (8998)。当 EPP 将 prefill 请求路由到 worker 节点（如 prefill-0-1）时，room 的 bootstrap 地址指向该 worker 的 8998（不存在），decode handshake 失败。

#### 修复：InferencePool 仅匹配主节点

```yaml
# pd-disaggregation.values.yaml
router:
  modelServers:
    matchLabels:
      llm-d.ai/guide: "pd-disaggregation"
      leaderworkerset.sigs.k8s.io/worker-index: "0"   # 仅 P/D 主节点
```

或直接 patch 现有 InferencePool：

```bash
kubectl -n metax-ai-pd patch inferencepool pd-disaggregation --type='json' -p='[
  {"op": "replace",
   "path": "/spec/selector/matchLabels/leaderworkerset.sigs.k8s.io~1worker-index",
   "value": "0"}
]'
```

修复后 EPP 端点只有 `prefill-0-rank-0` 和 `decode-0-rank-0` 两个主节点。

### 5.3 EPP 访问方式

EPP 使用 hostNetwork，通过节点 IP 直接访问：

```bash
# EPP pod 所在节点
EPP_NODE=$(kubectl -n metax-ai-pd get pod -l llm-d-router-gateway=pd-disaggregation-epp \
  -o jsonpath='{.items[0].spec.nodeName}')
EPP_IP=$(kubectl -n metax-ai-pd get node $EPP_NODE \
  -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

curl -X POST http://${EPP_IP}:8081/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{"model": "glm-5.1-w8a8", "prompt": "你好"}'
```

完整请求流：

```
Client → EPP node:8081 (hostNetwork Envoy)
  → prefill 阶段 → prefill-0:8000 → prefill modelserver (计算 KV)
  → decode 阶段  → decode-0:8000 → routing-proxy → decode modelserver:8200 (自回归生成)
```

### 5.4 注意事项

- EPP 重启后端点重新发现需要数秒，期间请求可能返回 400/404（瞬时抖动），稍等片刻后恢复。
- EPP pod 使用 hostNetwork，重启后可能调度到任意节点。通过节点 IP:8081 访问前需先确认 EPP 所在节点。

## 4. 端口对齐（llm-d 规范）

### 标准端口

| 组件 | 端口 |
|------|------|
| Prefill modelserver | 8000 |
| Decode modelserver | 8200 |
| Decode routing-proxy sidecar (EPP 入口) | 8000 |
| NIXL KV 传输 | 5600 |
| 分布式初始化 | 5000 |

### headless service 端口

decode-headless 需要暴露 `sidecar:8000` 端口，确保 EPP 通过 EndpointSlice 发现 routing-proxy：

```yaml
ports:
  - name: sidecar
    port: 8000
    targetPort: 8000
  - name: modelserver
    port: 8200
    targetPort: 8200
  - name: nixl
    port: 5600
    targetPort: 5600
  - name: dist-init
    port: 5000
    targetPort: 5000
```

---

## 6. MACA 沐曦环境变量补全

### 问题

`patch-prefill.yaml` 和 `patch-decode.yaml` 初始版本遗漏了大量 MACA 专属环境变量，可能导致 GPU 初始化失败。

### 修复

补全以下类别的环境变量，与沐曦参考脚本 `config.sh` 和 LWS/StatefulSet 模式对齐：

- **MACA SDK**: `MACA_PATH`, `MACA_QUEUE_SCHEDULE_POLICY`, `MACA_SMALL_PAGESIZE_ENABLE`
- **Triton MACA 优化**: `TRITON_DISABLE_MACA_OPT_MMA_PREFETCH`, `TRITON_ENABLE_MACA_CHAIN_DOT_OPT`, `TRITON_ENABLE_MACA_COMPILER_INT8_OPT`, `TRITON_ENABLE_MACA_OPT_MOVE_DOT_OPERANDS_OUT_LOOP`
- **Torch MACA**: `TORCH_MACA_ARCH_LIST`
- **MCCL 网络**: `MCCL_SOCKET_IFNAME`
- **MACA SHMEM**: `MXSHMEM_HCA_LIST`, `MXSHMEM_DISABLE_MACA_VMM`, `MXSHMEM_SYMMETRIC_SIZE`, `MXSHMEM_BOOTSTRAP_UID_SOCK_IFNAME`
- **GLOO**: `NV_SGLANG_GLOO_OPT`, `MX_SGLANG_GLOO_OPT` (decode only)
- **Python/系统**: `PYTHONFAULTHANDLER`, `PYTHONUNBUFFERED`, `RES_OPTIONS`

---

## 7. 镜像拉取策略

所有 Metax 配置的 `imagePullPolicy` 已统一为 `Always`，确保每次重启拉取最新镜像。

---

## 8. decode 启动失败 — `Not enough memory. Please try to increase --mem-fraction-static`

> 镜像：`v0.5.8-deepseek-v4-rc3-maca...`；症状出现在 **EAGLE draft worker** 初始化阶段，
> target 模型本身早已加载完成。

### 现象

```
[DP0 TP0 EP0] DSv4 pool sizes (DRAFT): using TARGET's pool sizes - full=312064, swa=30976
Scheduler hit an exception: ... model_runner_kv_cache_mixin.py:453, in init_memory_pool
RuntimeError: Not enough memory. Please try to increase --mem-fraction-static. Current value: 0.82
[Rank 0 scheduler is dead.]
```

关键点：报错发生在 **draft worker**（`EagleDraftWorker` → `TpModelWorker(is_draft_worker=True)`），
而不是 target；且 `DSv4 pool sizes (DRAFT)` 已经打印出来（说明 draft 的池配置正常拿到了
target 的尺寸），紧接着才抛内存异常。

### 根因（本 fork 的显存语义）

`model_runner.py:387`：

```python
self.total_gpu_memory = self.init_torch_distributed()
```

而 `init_torch_distributed()`（本 fork 修改过）返回的是 **`min_per_gpu_memory`
= 该 worker init 时刻的“可用”显存**，不是设备容量（上游返回设备总量）。于是每个
worker 都用“自己 init 时看到的可用显存”来算池：

```python
# model_runner_kv_cache_mixin.py profile_max_num_token()
rest_memory = available_gpu_memory - self.total_gpu_memory * (1 - mem_fraction_static)
```

draft worker 在 **target 完全初始化之后**（含 ~8.2 GB cuda graph）才创建，它看到的
“总量”只有 ~2.9 GB，而 draft 自身权重（2.36 GB）加载完只剩 ~0.48 GB，仍被要求保留
`(1-f) × 2.9 GB ≈ 0.515 GB`，于是 `rest_memory < 0` → `max_total_num_tokens <= 0` → raise。

判据（可用来定 mem_fraction）：

```
draft init 时可用显存  >  draft 权重 / mem_fraction_static
```

f=0.82 时需要 > 2.90 GB，实测只有 2.86 GB —— **差 42 MB**。

### 修复

降低 decode 侧 `mem_fraction_static`：每降 0.01 可给 draft 多留 ~0.6 GB，而门槛只抬高
~0.035 GB（`draft 权重 / f`）。本方案取 **0.78**：

| f | target `Memory pool end` 剩余 | draft init 可用 | draft 判据 | 结果 | KV pool |
|---|------|------|------|------|---------|
| 0.82 | 11.25 GB | 2.86 GB | 2.90 GB | ❌ 差 42 MB | 312064 token |
| 0.78 | 13.66 GB | 5.27 GB | 3.05 GB | ✅ 余 1.7 GB | 226304 token |

代价是 KV pool 变小（312K → 226K token/rank）。**调大 f 会让这里直接启动失败**，
不要按报错字面“increase --mem-fraction-static”。

厂商 `config.sh` 的 `get_decode_mem_fraction_static()` 表按 `(gpu_name, dp_size, mtp)`
取值（c550 有 0.76~0.83 多行），正是为匹配这条约束 —— 换 GPU/换 dp/换 MTP 档位时，
该值必须重新标定，不能照抄。

### 验证

```bash
kubectl -n metax-ai-pd logs decode-dsv4rc3-0 -c modelserver | grep -E "Memory pool end|DSv4 pool sizes \(DRAFT\)|Memory pool end|fired up"
# 期望: 出现 DSv4 pool sizes (DRAFT) 后不再抛异常，最终 "The server is fired up and ready to roll!"
```

---

## 9. decode/prefill 处理首个真实 PD 请求后整组卡死（未闭环）

### 现象

- `/health` 返回 **503**（挂起 ~20 s 后返回），日志刷屏：
  `Health check failed. Server couldn't get a response from detokenizer for last 20 seconds.`
- 该角色所有 rank 的 HTTP 全部无响应；`kubectl exec` 进去 curl 本机 `127.0.0.1` 也超时。
- scheduler 进程 CPU 打满（~240%/进程），但不再产生任何日志。
- 只有**处理过真实请求**的那个角色卡死：decode 在**首次 warmup 请求之后**卡死；
  prefill 在其他角色**首个真实请求**到达时卡死（liveness 探针连续失败 5 次后被 kubelet
  SIGTERM，LWS `RecreateGroupOnPodRestart` 于是把整组 4 个 pod 重建）。
- 未处理过请求的实例（例如关掉 EAGLE 后闲置的 decode）`/health` 正常 200 —— 
  **注意不要据此得出“EAGLE 是元凶”的结论**：该实例只是没被真实请求 exercise 过。

### 定位方法（镜像内自带 py-spy）

```bash
# 卡死 rank 上，找到 scheduler 进程
kubectl -n metax-ai-pd exec decode-dsv4rc3-0 -c modelserver -- bash -lc \
  'pid=$(ps -eo pid,cmd | grep "sglang::scheduler" | grep -v grep | awk "{print \$1}" | head -1); \
   /opt/conda/bin/py-spy dump --pid $pid --native'
```

原生栈（决定性证据）：

```
at::native::internal::UniqueCub<int>::operator()
  at::Tensor::item<long>()                      <- 等 GPU
    mcStreamSynchronize (maca runtime)
      mxr::Event::awaitCompletion
        mxr::SignalTracker::CpuWaitForSignal     <- CPU 空转等一个永不完成的 device signal
```

对应 Python 栈（leader rank）：

```
process_batch_result_prebuilt (scheduler_output_processor_mixin.py:63)
  release_kv_cache (common.py:469)
    cache_finished_req (chunk_cache.py:63)
      free (swa_memory_pool.py:429)              <- full_attn_allocator.free
        free (allocator.py:442)                  <- torch.unique(free_index // page_size)
          torch.unique ... item()
```

即：**stream 上前一个 kernel 永不完成**，`torch.unique` 里的 `item()`（D2H）就永远等不到，
scheduler 主循环卡住 → detokenizer 心跳停 → 整组 rank 阻塞在
`recv_requests → broadcast_pyobj`（TP 组其余 rank 的栈都停在这里，是受害者不是元凶）。

### 已排除 / 已对齐

| 假设 | 实验 | 结论 |
|------|------|------|
| EAGLE draft worker 显存 | §8 的 mem_fraction 修复 | 启动问题已解决；卡死仍复现 |
| 厂商 DSv4 环境变量缺失 | 补 `USE_SINGLE_STREAM_DISPATCH_OVERLAP=1`、`SGLANG_DEEPEP_BF16_DISPATCH=1`、`SGLANG_DSV4_FIX_TP_ATTN_A2A_SCATTER=False`、`MX_SGLANG_ENABLE_KV_LAYOUT_FIX=False` | 卡死位置完全不变（仍是 allocator.free → torch.unique）；这些变量本身仍需补齐（见 §10） |
| EAGLE 自身 | decode 关 `PD_SPECULATIVE_ENABLE=0` | ❌ 该实验**不成立**（实例没收到真实请求，天然不卡）；但 prefill（无 EAGLE、无 EPLB）同样卡死，说明**不是 EAGLE 特有** |

### 尚未验证的怀疑方向（按优先级）

1. **本 fork 与厂商已验证配置的参数偏差**：`--context-length` 200000（厂商 131072）、
   `--swa-full-tokens-ratio` 0.1（厂商 prefill 0.2 / decode 0.4）、`--max-running-requests`
   48/64（厂商 8×dp）、`--chunked-prefill-size` 4096、`--cuda-graph-max-bs` 64（厂商 8）、
   `USE_INDEX_CACHE=1`（厂商 `config.sh` 里是注释掉的）、`--enable-eplb` 无文件加载。
   建议**一次性对齐厂商 `decode.sh/prefill.sh` 的参考 argv** 再判定，
   比逐个 bisect（每次 ~6 分钟 + 整组重建）划算。
2. rc3 镜像本身的请求路径缺陷（偏离厂商默认后仍卡死则高度怀疑）。

### 影响

- EPP 侧：卡死角色 readiness 失败 → 请求无法路由；`FailOpen` 时表现为 5xx/超时。
- 卡死角色若被 liveness 打掉，LWS 会**整组重建**（`RecreateGroupOnPodRestart`），
  重建期间该角色完全不可用（约 6 分钟）。

---

## 10. router / sidecar 连通性矩阵（hostNetwork）

拓扑：`Client → EPP(envoy:8081 + epp ext-proc:9002) → decode sidecar:8000 → modelserver:8200`，
以及 `sidecar → prefill:8000` 的 prefill 腿。除 EPP 外全部 `hostNetwork: true`。

### 实测结果（从 hostNetwork pod 出发，纯 curl）

| 目标 | 结果 | 说明 |
|------|------|------|
| `10.66.3.32:8000/health`（decode sidecar） | ✅ 200 (1 ms) | sidecar 自身健康，与 modelserver 状态无关 |
| `10.66.3.33:8000/health`（prefill HTTP） | ✅ 200 | |
| `10.66.3.32:8200/health`（decode modelserver） | ✅ 200（引擎就绪后） | |
| `10.233.119.139:8081/health`（EPP envoy） | ✅ 200 | EPP 是 **pod 网络**，不是 hostNetwork |
| `10.66.1.232:9002/9003`（EPP ext-proc / health） | ❌ 拒绝 | EPP 不在宿主网络，且 9002/9003 只服务 gRPC |

### ⚠ 两个需要知道的点

**1) EPP 实际上不是 hostNetwork。** `router/pd-disaggregation.values.yaml` 里写了
`router: hostNetwork: true`，但实测 EPP pod 的 `hostNetwork` 为空、podIP 是 Calico 地址
（`10.233.x.x`），说明该 key 在 `llm-d-router-standalone-0.0.0` chart 上不生效。
当前功能上没问题（pod 网络 → 宿主 IP 可达，见上表），但若确实要“全 hostNetwork”，
需要按 chart 实际 schema（`helm show values`）改成正确的 key 并 `helm upgrade`。
验证：

```bash
kubectl -n metax-ai-pd get pod -l llm-d-router-gateway=pd-disaggregation-epp \
  -o jsonpath='{.items[0].spec.hostNetwork}{"\n"}'   # 期望 true，当前为空
```

**2) 直连 sidecar 会 400 —— 这是预期行为，不是故障。** decode modelserver 只接受
带 PD bootstrap room 的请求；bootstrap/`prefill host:port` 头由 **EPP** 注入
（`disagg-headers-handler` / `disagg-profile-handler`），因此：

```
# ❌ 绕过 EPP 直连 sidecar：decode 报 "Disaggregated request received without boostrap room id"
curl -X POST http://<decode-node-ip>:8000/v1/chat/completions ...

# ✅ 走 EPP
curl -X POST http://<epp-pod-ip>:8081/v1/chat/completions ...
```

端到端验收用 README §7 第 5 步（`curl http://<epp-ip>:8081/v1/chat/completions`）。
EPP 侧链路证据：`EPP received request` → `EPP sent request body response(s) to proxy`
→ decode sidecar 日志出现 `decoderURL":"http://localhost:8200"`。
（端到端目前会停在 §9 的请求卡死上，与 router 无关。）

---

## 11. official 模式（跑厂商脚本 + 适配层）的七个坑

默认启动模式改为 `official`：直接跑镜像内 `sglang/{prefill,decode}.sh`，适配层只做
「拓扑注入 + env→厂商变量回写 + Port/Host/Bootstrap 覆盖 + 摘要」。
厂商脚本的变量几乎全是 `readonly` 赋值（部分是 `$(...)` 函数调用），**只能靠 sed 改右侧**，
这也是 GPUStack `start_pd.sh` 的做法（只改容器可写层，不动镜像）。踩过的坑：

| # | 坑 | 现象 | 适配层如何处理 |
|---|----|------|----------------|
| 1 | 端口是 **9292(prefill)/9293(decode)** | llm-d sidecar/探针打 8000/8200 全失败 | 回写 `{prefill,decode}_server_port`（`SKIP_PORT_OVERRIDE` 非空则跳过） |
| 2 | HCA 名是 **`mlx5_bond_2..5` / `mlx5_bond_1`** | NCCL/NVSHMEM 找不到设备；`--disaggregation-ib-device` 指向不存在的卡（`config.sh:157`） | `PD_HCA_LIST` / `PD_MOONCAKE_IB_DEVICE` 回写 `hca_list` / `mooncake_ib_device` |
| 3 | 显存是 `get_*_mem_fraction_static(gpu,dp,mtp)` **查表**，表里（c550/mars-x201）**没有本 GPU** | 查空 → `--mem-fraction-static=""` → 启动失败（报错不直观） | `PD_MEM_FRACTION_STATIC` 整行回写（覆盖函数调用）；值受 §8 约束 |
| 4 | 模型路径硬编码 **`/bgfs/models/...`** | 容器里模型在 `/workspace/data/...`（hostPath），直接跑会找不到模型 | `PD_MODEL_PATH` 回写 `model_path_specific` |
| 5 | EPLB 文件默认指向镜像内**不存在**的 `/workspace/eplb/deepseek-v4/deepseek-v4.pt` | 拉起后才报路径不存在 | 文件存在才回写；否则回写空值=关闭 EPLB 并告警 |
| 6 | `--enable-metrics` 在厂商脚本里是**注释状态** | 本项目 Prometheus/Grafana 采不到指标 | `PD_ENABLE_METRICS=1`（默认）把该行取消注释 |
| 7 | 部分 env 是**版本分支**：`USE_SINGLE_STREAM_DISPATCH_OVERLAP` / `SGLANG_DEEPEP_BF16_DISPATCH` 只在 **v0.5.7** 分支 export | explicit 模式手工设上＝偏离厂商 0.5.8 路径（实测并不能消除 §9 卡死） | official 模式先 `unset` explicit 专用 env，交给厂商脚本按版本决定 |

### 验证方式（不需要真拉起）

```bash
# 1) 渲染 + dry-run: 只做回写与摘要, 不启动引擎
kubectl -n metax-ai-pd set env lws/decode-dsv4rc3 --list | head    # 确认 PD_DRY_RUN 已置
kubectl -n metax-ai-pd apply -k guides/pd-disaggregation/modelserver/gpu/sglang/metax/deepseek-v4-rc3-maca/lws/
kubectl -n metax-ai-pd logs decode-dsv4rc3-0 -c modelserver
# 期望看到: 每条「变量回写 ... -> ...」+「回写后的有效值」表
#           未回写的项会原样显示厂商公式 (例如 decode_dp_size: "$((nnodes * num_dies))")
#           即「未设=厂商默认」在摘要里是**可见**的

# 2) 抽查补丁后的厂商脚本 (容器可写层)
kubectl -n metax-ai-pd exec decode-dsv4rc3-0 -c modelserver -- \
  grep -nE "decode_(tp|dp|ep|pp)_size|mem_fraction|server_port|enable-metrics" \
  /workspace/llm-launch/sglang/config.sh
```

### 补充说明

- 回写清单与厂商默认值的对照表在 `README.md` §4「回写参数表」。
- `official` 模式**不再使用** `PD_DTYPE/PD_QUANTIZATION/PD_KV_CACHE_DTYPE/PD_LOAD_BALANCE_METHOD/
  PD_MOE_*` 等 explicit 专用项 —— 这些由厂商 `models/<spec>.sh` 的
  `prefill_decode_model_args` 提供（bf16 / w8a8_int8 / deepep low_latency / deep_gemm）。
- 若某变量厂商脚本并未覆盖而实际需要，从 `_official_unset_explicit_envs()` 清单里移除即可；
  反之要"多对齐"就把它加进去。


---

## 12. 新集群重部署实测（2026-09-24）：三个 manifest 缺陷

> 环境：新装 8 节点集群（k8s v1.32.5 / LWS v0.10.0 / 驱动 3.9.6 / 镜像不变）。
> 同一套 manifest 在新集群首部署即踩到下面三个问题，均已修复。**这三个都是
> manifest 自身的缺陷，与集群环境无关**，换集群部署前建议先确认已带上修复。

### 12.1 `kubectl apply` 被拒：同名 env 重复

#### 现象

```
Error from server (Invalid): error when creating ".../lws/":
LeaderWorkerSet... "decode-dsv4rc3" is invalid:
spec.leaderWorkerTemplate.workerTemplate.spec.containers[0].env[66]:
Duplicate value: map[string]interface {}{"name":"PD_HCA_LIST"}
```

#### 根因

`base/prefill.yaml` / `base/decode.yaml` 里两处 env 块都定义了同一个变量：

| 变量 | 第一次出现 | 第二次出现（重复） |
|------|-----------|------------------|
| `PD_HCA_LIST` | 「网卡 / disagg 设备」块（official 回写源） | 「沐曦平台环境」块 |
| `SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK` | 「── DeepEP ──」块 | 「沐曦平台环境」块 |

K8s 的 Pod 校验要求 env 名唯一，**整组 apply 直接失败**（不是运行期问题）。
两次的值相同，删掉后一处即可。

#### 修复

删除「沐曦平台环境」块里的重复项（`PD_HCA_LIST`、DeepEP token 上限），
在该处留注释指回第一次定义的位置。

#### 自查（改完 yaml 必做）

```bash
kubectl kustomize .../deepseek-v4-rc3-maca/lws/ > /tmp/r.yaml
python3 - <<'P'
import yaml, collections
for d in [x for x in yaml.safe_load_all(open('/tmp/r.yaml')) if x]:
    if d.get('kind')=='LeaderWorkerSet':
        sp=d['spec']['leaderWorkerTemplate']['workerTemplate']['spec']
        for key in ('initContainers','containers'):
            for c in sp.get(key) or []:
                n=[e['name'] for e in c.get('env',[])]
                dup=[k for k,v in collections.Counter(n).items() if v>1]
                print(f"{d['metadata']['name']}/{c['name']}: dup={dup or 'none'}")
P
```

### 12.2 official 模式启动 2 秒即退出：`CUDA_PATH: unbound variable`

#### 现象

宿主日志只有三行，之后什么都没有（容器 exit 1，`RecreateGroupOnPodRestart` 反复重建）：

```
/bin/bash: 5.1.16(1)-release
CPU: performance
SGLang version: v0.5.8
/workspace/llm-launch/sglang/config.sh: line 178: CUDA_PATH: unbound variable
```

> ⚠ 第一行 `/bin/bash: 5.1.16(1)-release` **不是报错**，是厂商 `common.sh:3` 的
> `echo "$SHELL: $BASH_VERSION"`；真正的报错在最后一行。这条极易误诊为
> "bash 版本问题"。

#### 根因

`pd-launcher.sh` 的 `_official_unset_explicit_envs()` 把 `CUDA_PATH` 也清掉了，
但厂商 `config.sh:178` 是**读**这个变量：

```bash
readonly cuda_home cuda_path_bak="$CUDA_PATH"   # 存下调用方的值...
export_multi_arch "CUDA_PATH" "$cuda_home"      # ...换成厂商探测到的 cuda_home...
export CUDA_PATH="$cuda_path_bak"               # ...再恢复
```

厂商脚本假设调用方已经设了它（官方 docker 指南即 `-e CUDA_PATH=/opt/maca/tools/cu-bridge`），
自己并不初始化。在 `set -euE` 下读未定义变量 → 立即 fatal。

#### 修复

从 `_official_unset_explicit_envs()` 的清单里移除 `CUDA_PATH`（pod env 里已有该值）。

#### 同类风险自查

清单里其余变量是否也被厂商脚本"读而不设"？静态扫描结论（rc3 镜像）：

```bash
# 对清单里每个变量, 在厂商树里找"被读取且未被赋值"的用法
for v in $(清单); do grep -rn "\$$v" /workspace/llm-launch --include="*.sh"; done
```

只有两处命中，且只有 `CUDA_PATH` 在启动路径上：
- `config.sh:178`（**致命**，本次已修）
- `deepep/low-latency.sh:53`（仅被 `deepep/tmux-config.sh` 使用，且自己先赋值，无影响）

### 12.3 decode 永远卡在 `1/2`：ClusterIP 不能当 `--dist-init-addr`

#### 现象

- decode 4 个 pod 恒为 `1/2`（只有 routing-proxy sidecar ready），prefill 正常 `1/1`
- decode 日志停在 MACA 版本检查后**再无输出**；GPU 显存 ~0.8 GB、利用率 0%（权重根本没加载）
- 约 10 分钟后整组重建，然后永远循环

py-spy 看进程（镜像自带，见 §9）：

```
# python3 -m sglang.launch_server : _wait_for_scheduler_ready (engine.py:855)
# sglang::data_parallel_controller:
#     _broadcast_ports_as_server (data_parallel_controller.py:335)  <- 阻塞在 zmq_msg_recv
#     _broadcast_worker_ports (…:315) / launch_dp_attention_schedulers (…:386)
```

即：**node0 在等其余 3 个节点来握手，而它们永远到不了**；`sglang::scheduler`
进程一个都没起来。

#### 根因

decode 开了 `--enable-dp-attention`（`dp=32`）。sglang 会从 `--dist-init-addr`
**推导出一个 ZMQ 握手端点**（`data_parallel_controller.py:308`）：

```python
host, port = server_args.dist_init_addr.split(":")
endpoint = f"tcp://{host}:{int(port) + DP_ATTENTION_HANDSHAKE_PORT_DELTA}"  # DELTA=13
```

- node0 在 `tcp://<dist_init_host>:5013` 上 bind 一个 REP socket；
- 其余 3 个节点 `_receive_ports_as_client` **直连 node0**（这是点对点语义）。

而集群上的 `decode-dist-master` 是 **ClusterIP**。ClusterIP 是虚拟 IP，且作为
本地地址存在于**每一台**节点上（`kube-ipvs0`），同时 IPVS 里**没有 5013 这个
端口的 service 规则**。于是：

| 谁 | 行为 |
|----|------|
| node0 | bind ClusterIP:5013 —— 成功（kube-ipvs0 上有这个地址），然后永久阻塞在 recv |
| 其余节点 | 连 ClusterIP:5013 → 目标地址是**自己这台的本地地址**，包不出节点 → Connection refused |
| 其余节点的 DP controller | 600s `RCVTIMEO` 超时 → `RuntimeError` → 容器退出 |
| LWS | `RecreateGroupOnPodRestart` → 整组重建 → 回到第 1 行，无限循环 |

> prefill 是 `dp=1`（tp=4 × pp=8），**不走**这条 dp-attention 握手路径，所以
> 它填 ClusterIP 也能起 —— 这正是该 bug 隐蔽的原因：一半拓扑正常，一半死锁。

实测佐证（从 node33 连 leader 所在 node34）：

```
ClusterIP:5013  -> Connection refused
nodeIP:5013     -> Connection refused   # 当时 node0 已因超时退出, 无人监听
```

#### 修复

`PD_MASTER_IP` **留空**，交给 `pd-launcher` 解析到 leader 的**真实宿主机 IP**：

```
rank0           → 自身 POD_IP（hostNetwork ⇒ 即宿主机 IP，正是 master）
rank1-3         → K8s API 查 leader pod(<lws>-0) 的 status.podIP
                  （依赖 rbac.yaml 的 mx-sglang-pd-pod-reader）
```

日志确认：

```
[pd-launcher] master 来源: K8s API leader 'decode-dsv4rc3-0' -> 10.66.3.35
[pd-launcher] Dist Init Addr  : 10.66.3.35:5000
```

`services.yaml` 的 `*-dist-master` ClusterIP 保留，但仅作**客户端**入口
（sglang 对比网关 `router.yaml` 的 `PD_PREFILL_ENDPOINTS`/`PD_DECODE_ENDPOINTS`
就是填它 —— 普通 TCP 连接走 IPVS 单点转发没问题）。

#### 一句话判据

> 凡是 **`--dist-init-addr` 传给 sglang 的地址**，必须是 leader 的**真实 IP**；
> ClusterIP / VIP / DNS 轮询名都不行。只有"客户端连服务"的用法才可以用 ClusterIP。

---

## 13. 换镜像 0.5.13-maca（+ 改走 explicit 模式）踩到的六个坑（2026-09-24）

> 起因：新集群驱动栈是 MACA 3.8.1.3 / 内核模块 3.9.6，与 rc3 镜像的用户态 3.7.1.9 不匹配，
> decode 在 CUDA graph 捕获期稳定报 `mcErrorIllegalAddress`（内核 `invalid_xvm_pde`，多节点复现）。
> 处置：换成 `harbor.isuanova.com/metax/sglang:0.5.13-maca.ai3.8.1.3-torch2.10-py312-ubuntu22.04-amd64`。
> ⚠ 该镜像**不带厂商 llm-launch 脚本**，因此两个 LWS 都改用 `PD_LAUNCH_MODE=explicit`
> （标准 `sglang.launch_server` 命令），argv 按厂商 0.5.8-rc3 的实测命令 1:1 翻译。

### 13.1 镜像缺 `ip` / `curl` / `jq`（rc3 镜像有）

```console
$ kubectl exec <pod> -- bash -c 'command -v ip curl jq'
ip        MISSING
curl      MISSING
jq        MISSING
awk/grep/python3  /usr/bin/...
```

影响两处（都已改为零依赖实现）：

| 用途 | 旧实现 | 现实现 |
|------|--------|--------|
| 探测主网卡 | `ip route get 8.8.8.8` | 优先 `ip`；没有则 `awk '$2=="00000000"{print $1;exit}' /proc/net/route` |
| 查 leader pod IP | `curl` + K8s API | `python3 - ${pod} ${ns} ${token}` + urllib（stdlib） |

### 13.2 ⚠ 网卡名不能写死 `manage0`（本集群 node 28 是特例）

`mxgpu-3-28` 的 IP 在 **br-lan** 上、`manage0` **没有地址**（其余 7 台节点恰好相反）。
写死 `GLOO_SOCKET_IFNAME=manage0` 会直接：

```
RuntimeError: [enforce fail at .../gloo/transport/tcp/device.cc:84] ifa != nullptr.
Unable to find address for: manage0
```

（栈在 `ModelRunner.init_torch_distributed`，整个 scheduler 全灭。）

修法：`PD_SOCKET_IFNAME=auto`（默认），由 pd-launcher 按**默认路由出口网卡**探测后导出
`GLOO_/NCCL_/MCCL_SOCKET_IFNAME` 与 `NVSHMEM_/MXSHMEM_BOOTSTRAP_UID_SOCK_IFNAME`
—— 这正是厂商 `get_net_primary_iface` 的语义，official 模式下天然跟着节点走。

### 13.3 ⚠ `set -euo pipefail` + 命令替换 = **静默退出**（极难排查）

```bash
_iface="$(ip route get 8.8.8.8 | grep -oP '(?<=dev )\S+' | head -1)"   # ❌
```
`ip` 不存在（13.1）→ 管道返回非 0 → `set -e` 直接杀掉整个脚本，
**日志里一行错误都没有**（容器 exit 1，日志停在上一行）。

凡是在 `$( )` 里跑可能失败的命令，一律 `{ ...; } || true`：

```bash
i="$( { ip route get 8.8.8.8 2>/dev/null | grep -oP '(?<=dev )\S+' | head -1; } || true)"
```

另外：日志经 `tee -a` 落盘，容器被杀时**缓冲区里的最后几行会丢**，
排查"没有报错就退出"时不要只看日志文件 —— 用 `kubectl exec` 手动复现
（本仓库做法：起一个同镜像/同节点/同 env 的 `sleep` 调试 pod，再 `bash -x` 跑 launcher）。

### 13.4 decode 报 `TypeError: ... unexpected keyword argument 'topk_weights'`

```
File ".../sglang/srt/layers/moe/token_dispatcher/deepep.py", line 833, in low_latency_dispatch
TypeError: Buffer.low_latency_dispatch() got an unexpected keyword argument 'topk_weights'
```

**不是 rc3 遗留，恰恰相反 —— 必须把 `SGLANG_DEEPEP_BF16_DISPATCH=1` 设回来**：

- 镜像自带 `deep_ep.Buffer.low_latency_dispatch` 的签名里**没有** `topk_weights`；
- 而 sglang 的 `deepep.py:833` 只在 `use_fp8=True` 时才传它；
- `use_fp8` 保持 False 的条件之一正是
  `backend.is_deep_gemm() and envs.SGLANG_DEEPEP_BF16_DISPATCH.get()`。

即：**`--moe-runner-backend=deep_gemm` 必须配 `SGLANG_DEEPEP_BF16_DISPATCH=1`**，否则 scheduler 全灭。

### 13.5 decode 报 `AttributeError: 'NoneType' object has no attribute 'shape'`（EAGLE draft 抓图）

```
deepseek_v2.py:1361, in _forward_shared_experts
    bs = hidden_states[0].shape[0] if isinstance(hidden_states, tuple) else hidden_states.shape[0]
AttributeError: 'NoneType' object has no attribute 'shape'
```

- 触发点：**EAGLE draft worker 的 CUDA graph 捕获**（target 的抓图已通过）；
- 链条：`deepseek_v4_nextn.py:196 → deepseek_v4.py:1505 → deepseek_v2.py:879 forward_deepep`，
  而 `deepseek_v4.py:1489` 的 `elif _use_tp_moe_gather:` 分支用
  `get_global_dp_buffer()` 取全局 DP 缓冲；该缓冲在 draft runner 上下文里没被初始化 →
  传给 `self.mlp()` 的 `hidden_states` 是 `None`。
- `_use_tp_moe_gather = (not _use_cp) and get_attention_dp_size() > 1 and not moe_a2a_backend.is_none()`
  → 我们 `dp=32 + deepep` 必然命中，**没有开关能绕开**。

**当前取舍**：`PD_SPECULATIVE_ENABLE=0` 临时关掉 EAGLE，decode 即可正常起（本方案已用此配置跑通端到端）。
代价是失去 MTP 投机解码（decode 吞吐明显下降）。

**正解方向**：用本仓库自己的适配镜像
（`harbor.isuanova.com/metax/sglang:0.5.13-dsv4-adapter-r5` 等，已打过 DSv4 补丁 ——
实测其 `deepseek_v2.py` 的 `_forward_shared_experts` 调用点与基础镜像不同），
确认后把 `lws/kustomization.yaml` 的 `newTag` 换过去并把 `PD_SPECULATIVE_ENABLE` 改回 `1`。

### 13.6 其余与 rc3 的差异（已按新镜像调整）

| 项 | 处理 |
|----|------|
| `SGLANG_DSV4_FIX_TP_ATTN_A2A_SCATTER` | 新镜像默认 True（rc3 fork 要 False），**不再设置**，用镜像默认 |
| `USE_INDEX_CACHE` / `MX_SGLANG_ENABLE_KV_LAYOUT_FIX` / `USE_SINGLE_STREAM_DISPATCH_OVERLAP` | 新镜像里**已无这些变量**，从 yaml 删除 |
| `--cuda-graph-max-bs` / `--max-prefill-tokens` | 厂商只给 decode 传前者、两个都不传后者；launcher 改为**显式设了才传** |
| dp-attention / ep / moe / deepep 相关 flag | 厂商 prefill 一个都不传；launcher 改为按 `PD_DP_SIZE>1` / `PD_EP_SIZE` / `PD_MOE_A2A_BACKEND` **按需拼装** |
| prefill | 厂商用 `--disable-cuda-graph`（不抓图）→ 经 `PD_EXTRA_ARGS` 传入；这也是 graph 捕获类故障不会出现在 prefill 的原因 |

### 13.7 探针与整组重建（按用户要求放宽）

`restartPolicy: RecreateGroupOnPodRestart` 下**任一容器重启都会整组重建**（重载 32 卡权重 ≈ 4-6 min），
因此探针要容忍慢启动/瞬时无响应：

| 探针 | 旧 | 新 |
|------|----|----|
| startupProbe | initialDelay 60/90s, period 30s, failureThreshold 180 (≈90min) | initialDelay 120s, period 30s, **failureThreshold 236 (≈120min)** |
| livenessProbe | period 10s, timeout 5s, failureThreshold 5 (≈50s) | period 15s, timeout 10s, **failureThreshold 40 (≈10min)** |
| readinessProbe | period 5s, failureThreshold 3 | period 10s, failureThreshold 6 |

### 13.8 待办：对比网关（sglang router）在新镜像下 PD 工作流失败

换到 0.5.13-maca 后，`deepseek-v4-rc3-router`（对比网关 Deployment，`:8001`）：
`/health` 200，但请求会挂住到超时，日志里是
`smg::workflow::event ... Step failed`。

- 说明：**这只是对比入口**，规范入口 llm-d EPP 不受影响（实测 1.1s 正常返回）。
- 初步判断：0.5.13 的 `sglang_router` PD 参数语义可能变了
  （当前 argv 沿用 rc3 时的 `--pd-disaggregation --prefill <ClusterIP>:8000 <bootstrap_port> --decode <ClusterIP>:8200`）。
- 处置建议：核对 `sglang_router.launch_router --help`（新镜像内），或暂时把
  `base/router.yaml` 从 `base/kustomization.yaml` 的 resources 里去掉。
- ⚠ 另注：router 是 hostNetwork + 固定端口，**滚动更新会因端口占用死锁**
  （新 pod 一直 Pending: `didn't have free ports`）→ 先删旧 pod 等新 pod 落位即可。
