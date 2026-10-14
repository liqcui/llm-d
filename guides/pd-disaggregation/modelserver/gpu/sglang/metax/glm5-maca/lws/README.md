# GLM-5.1 — PD 分离部署方案（llm-d 规范，LeaderWorkerSet）

> 本目录是 GLM 的**独立自包含部署方案**（LWS + pd-adapter 模式），参照 `deepseek-v4-flash/lws/` 结构，
> 与旧 GLM 方案（`metax/lws/`、glmpd 镜像）和 DeepSeek 方案（`deepseek-v4-flash/lws/`）互不覆盖。
> 镜像与参数对齐 GPUStack 版本配置 `maca-sglang-glm-pd-custom`（rc4 镜像 + start_pd.sh 适配层），
> 网络/拓扑对齐「Kubernetes 基于 hostNetwork 的沐曦 GPU PD 分离部署」文档（StatefulSet 版）。

**验收状态**：⏳ 待部署验证（资产就绪，未跑端到端）

---

## 1. 方案概览

| 项 | 值 |
|----|----|
| 模型 | `GLM-5.2-W8A8`（宿主机 `/data/GLM-5.2-W8A8`，hostPath 挂载 `/workspace/data`；路径可经 `SGLANG_MODEL_PATH` 覆盖） |
| 镜像 | `harbor.isuanova.com/metax/sglang:v0.5.12-glm5-rc4-maca.ai.3.7.1.13-torch2.8-py310-ubuntu22.04-amd64`（`imagePullPolicy: Always`；registry 为仓库惯例占位，实际 harbor 地址按需替换） |
| 拓扑 | **4 Prefill + 4 Decode（1 个逻辑实例）**：LWS `replicas=1, size=4`（4 节点 × 8 卡 = 32 卡/角色） |
| Prefill 并行 | TP=8 PP=4 DP=1（跨 4 节点，`PD_PREFILL_PP_SIZE=4` ⇒ TP=nnodes×8/pp=8） |
| Decode 并行 | TP=32 DP=32 EP=32，MTP=4，PP=1 |
| 网关 | **llm-d EPP**（`InferencePool pd-disaggregation` + `pd-disaggregation-epp`，替代 sglang router）+ **glm5-router**（sglang_router，压测对比入口） |
| 访问入口 | `http://pd-disaggregation-epp.metax-ai-pd.svc:80/v1/chat/completions`（envoy :8081） |
| 启动方式 | 镜像内官方 llm-launch 脚本（`prefill.sh`/`decode.sh` + `models/glm-5.sh`），由 ConfigMap 挂载的 `pd-adapter.sh` 适配层驱动 |

## 2. 架构

```
Client → EPP (InferencePool: guide=pd-disaggregation, targetPort=8000)
             │
             └──→ decode pod 的 routing-proxy sidecar (:8000)
                      ├── ① Prefill leg ──→ prefill:8000（TP8/PP4，算 KV）
                      │                        │ NIXL/RDMA (mlx5_0)
                      └── ② Decode leg ───→ 同 pod modelserver:8200（TP32/DP32/EP32，自回归生成）
```

| 端口 | 组件 |
|------|------|
| 8000 | prefill modelserver（EPP/sidecar 直连）；decode routing-proxy sidecar（EPP 入口） |
| 8200 | decode modelserver |
| 8998 | prefill PD bootstrap（sglang 默认；llm-d sidecar kv-connector=sglang 按此端口查询） |
| 5600 / 5000 | nixl KV 传输 / dist-init |
| 8001 / 29000 | glm5-router HTTP / Prometheus |

> 与 hostNetwork StatefulSet 文档的差异：文档中 prefill 监听 9292、decode 监听 40006、gateway 监听 8001
> 是 STS + sglang gateway 的端口约定；llm-d LWS 规范统一为 8000/8200/8998（EPP + routing-proxy sidecar 依赖），
> 功能等价。

## 3. 目录结构

```
glm5-maca/lws/
├── kustomization.yaml   # 部署入口 (namespace: metax-ai-pd)
└── base/
    ├── prefill.yaml     # LWS prefill-glm5: replicas=1 size=4, 端口 8000+8998+5600+5000
    ├── decode.yaml      # LWS decode-glm5:  replicas=1 size=4, modelserver 8200 + routing-proxy sidecar 8000
    ├── router.yaml      # glm5-router Deployment (sglang_router, 压测对比入口, 8001)
    ├── services.yaml    # prefill-glm5-headless + decode-glm5-headless (EPP 发现)
    ├── serviceAccount.yaml
    └── pd-adapter-configmap.yaml  # pd-smart-adapter-glm5 (GLM PD 适配层, 调参/兼容修复, 不进镜像)
```

## 4. 镜像与升级

**直接使用官方镜像，无需构建。** 节点上镜像由 `imagePullPolicy: Always` 自动拉取；若 harbor 访问不稳，
fallback: `docker save` → `ctr import`（参照 `scripts/save-images.sh`）。

**升级到新版本（最小变更）**：改 `prefill.yaml` / `decode.yaml` / `router.yaml` 的 `image` 字段
→ 删 LWS 重建（`kubectl delete lws prefill-glm5 decode-glm5 -n metax-ai-pd` → 等 120s 连接清理 →
`kubectl apply -k .../glm5-maca/lws/`）。端口/bootstrap/host/metrics 等兼容修复由 pd-adapter §3.5
幂等补足，模型路径由 `SGLANG_MODEL_PATH` env 决定，一般无需改脚本。

## 5. 部署

```bash
# 0) 前置: LWS CRD、InferencePool/EPP 已装（Helm 管理，本方案不包含）；
#         模型已分发到全部候选节点（/data/GLM-5.2-W8A8）
# 1) 节点标签 (hostNetwork 端口冲突, 各角色节点互斥)
kubectl label node mxgpu-1-147 mxgpu-1-152 mxgpu-1-154 mxgpu-1-165 \
    metax-sglang-pd-prefill-glm5=true --overwrite
kubectl label node mxgpu-1-166 mxgpu-1-167 mxgpu-1-168 mxgpu-1-169 \
    metax-sglang-pd-decode-glm5=true --overwrite
kubectl label node mxgpu-1-232 metax-sglang-pd-router-glm5=true --overwrite
# 2) 部署
kubectl apply -k guides/pd-disaggregation/modelserver/gpu/sglang/metax/glm5-maca/lws/
# 3) 更新 glm5-router 中注册的 master IP (prefill-glm5-0-0 / decode-glm5-0-0 实际节点)
kubectl get pods -o wide -n metax-ai-pd | grep -E "prefill-glm5-0-0|decode-glm5-0-0"
```

**验证**：

```bash
kubectl -n metax-ai-pd get pods -w   # decode 大模型加载需要 5-10 分钟
export IP=$(kubectl -n metax-ai-pd get service pd-disaggregation-epp -o jsonpath='{.spec.clusterIP}')
curl -X POST http://${IP}/v1/chat/completions \
    -H 'Content-Type: application/json' \
    -d '{"model": "GLM-5.2-W8A8", "messages": [{"role": "user", "content": "你好"}], "max_tokens": 32}' | jq
```

## 6. PD Smart Adapter（调参适配层，ConfigMap 挂载，不进镜像）

`pd-adapter-configmap.yaml` 以 ConfigMap 形式挂载到 `/workspace/llm-d/pd-adapter.sh`（只读），
pod 命令只需一行 `bash /workspace/llm-d/pd-adapter.sh`。它**不修改镜像内 config.sh /
prefill.sh / decode.sh / models/glm-5.sh 源脚本**，在容器可写层做运行时 sed 回写，并打印启动摘要
（拓扑 + 全部可调参数有效值 + Entry Addr + Final Call）。

**§3.5 llm-d 兼容修复（幂等自动应用，无需 env）**：prefill/decode 端口 8000/8200、
PD bootstrap 8998（config.sh 显式设置时才改写）、`--host=0.0.0.0`、`--enable-metrics` ——
镜像未内置时自动补上；已内置时模式不匹配自动跳过，同一套脚本新旧镜像通用。

**换模型 / 换镜像的通用流程**：① 改 yaml `image` 字段 + （可选）`SGLANG_MODEL_PATH` env →
部署完成，无需改脚本。

**可调参数**（未设置则保持镜像内脚本默认值）：

| env | 作用 | 本方案默认 |
|-----|------|------|
| `SGLANG_CONTEXT_LENGTH` | 上下文长度（→ `context_length_specific`） | 200000 |
| `SGLANG_MODEL_PATH` | 模型路径（→ `model_path_specific`） | /workspace/data/GLM-5.2-W8A8 |
| `SGLANG_PREFILL_MAX_RUNNING_REQUESTS_PRE_BATCH` | prefill 批内最大请求数（GLM 故障二规避值 32） | 32 |
| `PD_CHUNKED_PREFILL_SIZE` | prefill 分块大小 | 14336 |
| `PD_PREFILL_PP_SIZE` | prefill 流水并行度（TP=nnodes×8/pp 自动算） | 4 |
| `PD_MEM_FRACTION_STATIC` | KV 池显存占比（0.9 曾触发碎片化 OOM） | 0.8 |
| `PD_DECODE_MAX_RUNNING_REQUESTS` | decode 最大运行请求数 | 16 |
| `PD_DECODE_MTP` | MTP 推测解码 draft tokens（**=1 关闭推测解码**） | 4 |
| `PD_DECODE_DP_SIZE` / `PD_DECODE_EP_SIZE` | decode 数据/专家并行度 | 32 / 32 |
| `PD_DECODE_DISABLE_CUDA_GRAPH` | decode 改走 eager（graph capture 与运行时回退不兼容时） | 未设置 |
| `SGLANG_QUANTIZATION` | 量化方式 | compressed-tensors（decode） |
| `SGLANG_DISAGGREGATION_QUEUE_SIZE` | PD 传输队列深度 | 8 |
| `SGLANG_DISAGGREGATION_THREAD_POOL_SIZE` | PD 线程池 | 24 |
| `SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT` | PD bootstrap 等待超时 | 6000 |
| `PD_MODEL_SPEC` | 模型脚本名（默认 `glm-5` → `models/glm-5.sh`） | glm-5 |
| `LLM_LAUNCH_DIR` | 镜像内启动脚本目录（默认 `/workspace/llm-launch/sglang`） | 见左 |

**调试**：`PD_DRY_RUN=1` 只打印摘要不拉起引擎（排障/验证用）。

## 7. 验收清单（待部署后执行）

```bash
# 1) Pod 就绪: prefill 4×1/1 Ready, decode 4×2/2 Ready (modelserver + routing-proxy)
kubectl -n metax-ai-pd get pods -l 'llm-d.ai/guide=pd-disaggregation'

# 2) P/D health = 200
curl -s -o /dev/null -w "%{http_code}\n" http://<prefill-ip>:8000/health     # 4 个 prefill 节点
curl -s -o /dev/null -w "%{http_code}\n" http://<decode-ip>:8200/health      # 4 个 decode 节点

# 3) PD bootstrap 8998 = 200 (不能 timeout/refused)
curl -s -o /dev/null -w "%{http_code}\n" "http://<prefill-ip>:8998/route?prefill_dp_rank=-1&prefill_cp_rank=-1&target_tp_rank=-1&target_pp_rank=-1"

# 4) Metrics 有数据 (pd-adapter §3.5 注入 --enable-metrics)
curl -s http://<prefill-ip>:8000/metrics | grep -v '^#' | wc -l    # > 0
curl -s http://<decode-ip>:8200/metrics  | grep -v '^#' | wc -l    # > 0

# 5) EPP 发现 2 个端点 (prefill-glm5-0-0 / decode-glm5-0-0)
kubectl -n metax-ai-pd logs deploy/pd-disaggregation-epp -c epp | grep -oE '"endpoint":"metax-ai-pd/[a-z0-9-]+-rank-0"'

# 6) 端到端 (完整链路: EPP + sidecar + Prefill + bootstrap + RDMA KV + Decode)
curl -s --max-time 120 -X POST http://pd-disaggregation-epp.metax-ai-pd.svc:80/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"GLM-5.2-W8A8","messages":[{"role":"user","content":"请只回复 OK"}],"max_tokens":16,"temperature":0}'
# 期望: choices[0].message.content == "OK"
```

## 8. 排障

| 现象 | 原因 | 解决 |
|------|------|------|
| Pod Pending, `didn't match Pod's node affinity/selector` | 节点缺标签 | `kubectl label node <name> metax-sglang-pd-prefill-glm5\|decode-glm5=true` |
| Pod Pending, `didn't have free ports` | hostNetwork 端口冲突（与旧 GLM/DSv4 方案并存） | 检查 8000/8200/8998/5600/5000 占用；本方案与 `metax/lws/`、`deepseek-v4-flash/lws/` **互斥**，同节点不可并存 |
| `mxkwCreateQueueBlock timeout` (日志) | MACA 驱动初始化**正常瞬态** | 等待 2-5 分钟自动消失 |
| decode startup probe `connection refused` | 大模型加载中 | 正常，startup probe 容忍 180 次失败（约 90 分钟） |
| prefill readiness `HTTP 404` | SGLang prefill 模式不暴露 `/v1/models` | 已配置 readiness 用 `/health` |
| `kubectl apply -k` 报 webhook 超时 / LWS controller nil pointer | LWS webhook 不可达 / v0.9.0 controller bug | 参照 `README.metax-lws.md` §6.1 绕过或升级 LWS / 改用 STS |
| 启动报 `ErrorNoBinaryForGpu xcore1000` (C500 JIT target) | 镜像未内置 C500 JIT 适配 | 参照 `deepseek-v4-flash/lws/README.md` §8.1 的 nvcc→cucc wrapper 方案（本方案未默认启用） |
| glm5-router 请求 502 / 路由到错误实例 | LWS 重建后 master 落点漂移 | `kubectl get pods -o wide \| grep glm5` 确认 master IP，更新 router.yaml 后 `kubectl rollout restart deploy/glm5-router` |
| 跳板机 curl 旧端口 (9292/40006/30001) 返回异常 | 旧 GLM gateway 遗留（NodePort DNAT 劫持） | 清理旧 `gateway-pod` / `mx-sglang-pd-gateway-svc` |

## 9. 与旧 GLM 方案（metax/lws/）的差异

| 项 | 旧 GLM（metax/lws/） | 本方案（glm5-maca/lws/） |
|----|----------------------|--------------------------|
| 模型 | GLM-5.2-W8A8 | GLM-5.2-W8A8（默认同款；`SGLANG_MODEL_PATH` 可切 5.1） |
| 镜像 | `glmpd`（llm-launch-GLM5 布局） | `v0.5.12-glm5-rc4-...`（与 GPUStack `maca-sglang-glm-pd-custom` 同源，/workspace/llm-launch 布局） |
| 启动 | pod 内联 sed 调参 + 直接 `prefill.sh/decode.sh` | pd-adapter ConfigMap 适配层（LWS 拓扑解析 + 幂等兼容修复 + 启动摘要） |
| 调参 | env → 内联 sed（写死在 yaml） | env → pd-adapter 统一回写（新镜像自动跳过已内置项） |
| 日志 | /var/log/sglang | /var/log/sglang-glm5 |
| 节点标签 | `metax-sglang-pd-prefill\|decode` | `metax-sglang-pd-prefill\|decode-glm5`（与旧方案节点互斥） |
| 可调参数 | 部分（context/mem/max_rq/model） | 全量（+pp/dp/ep/mtp/quantization/chunked/dry-run） |
