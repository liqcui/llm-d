# DeepSeek-V4-Flash — PD 分离部署方案（llm-d 规范，已验收通过）

> 本目录是 DeepSeek-V4-Flash 的**独立部署方案**，与 GLM 方案（`guides/pd-disaggregation/modelserver/gpu/sglang/metax/lws/`、`README.metax-lws.md`）互不覆盖。
> 未来新增方案（不同模型 / 不同拓扑 / 不同网关）请在 `modelserver/gpu/sglang/metax/` 下另建目录，保持各方案独立。

**验收状态**：✅ 2026-08-15 端到端验证通过（EPP → routing-proxy → Prefill → RDMA KV → Decode → "OK"）

**当前状态**：⏪ 2026-08-16 回退至 `0.5.12-dsv4` + `DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8`（新版本 patch 性能不达标，等待官方正确版本后以最小变更升级）

> 📖 客户端接入（集群外直连、curl/SDK 示例、压测注意事项）见独立文档 [../ACCESS.md](../ACCESS.md)。

---

## 1. 方案概览

| 项 | 值 |
|----|----|
| 模型 | `DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8`（宿主机 `/data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8`，hostPath 挂载；模型路径由镜像内 `models/deepseek-v4-flash.sh` 决定） |
| 镜像 | `harbor.mycompany.com/metax/sglang:0.5.12-dsv4`（`imagePullPolicy: Always`） |
| 拓扑 | **4 Prefill + 4 Decode**：LWS `replicas=4, size=1`（每个 1 节点 8 卡，prefill TP1/PP8，decode TP8/DP8/EP8） |
| 网关 | **llm-d EPP**（`InferencePool pd-disaggregation` + `pd-disaggregation-epp`，替代 sglang router） |
| 访问入口 | `http://pd-disaggregation-epp.metax-ai-pd.svc:80/v1/chat/completions`（envoy :8081） |

## 2. 架构

```
Client → EPP (InferencePool: guide=pd-disaggregation, targetPort=8000)
             │
             └──→ decode pod 的 routing-proxy sidecar (:8000)
                      ├── ① Prefill leg ──→ prefill:8000（TP1/PP8，算 KV）
                      │                        │ mooncake RDMA (mlx5_0)
                      └── ② Decode leg ───→ 同 pod modelserver:8200（自回归生成）
```

| 端口 | 组件 |
|------|------|
| 8000 | prefill modelserver（EPP/sidecar 直连）；decode routing-proxy sidecar（EPP 入口） |
| 8200 | decode modelserver |
| 8998 | prefill PD bootstrap（sglang 默认；llm-d sidecar kv-connector=sglang 按此端口查询） |
| 5600 / 5000 | nixl KV 传输 / dist-init |

## 3. 目录结构

```
deepseek-v4-flash/lws/
├── kustomization.yaml   # 部署入口 (namespace: metax-ai-pd)
└── base/
    ├── prefill.yaml     # LWS prefill-dsv4: replicas=4 size=1, 端口 8000+8998
    ├── decode.yaml      # LWS decode-dsv4: replicas=4 size=1, modelserver 8200 + routing-proxy sidecar 8000
    ├── pd-adapter-configmap.yaml  # PD Smart Adapter (调参/摘要, ConfigMap 挂载, 不进镜像)
    ├── services.yaml    # prefill-headless (8000/8998/5600/5000) + decode-headless (8000/8200/5600/5000)
    └── serviceAccount.yaml
```

## 4. 镜像与升级

**当前直接使用官方镜像，无需构建。** 节点上镜像由 `imagePullPolicy: Always` 自动拉取；若 harbor 访问不稳，fallback: `docker save` → `ctr import`。

**升级到新版本（最小变更）**：改 `prefill.yaml` / `decode.yaml` / `router.yaml` 的 `image` 字段 → 删 LWS 重建（`kubectl delete lws prefill-dsv4 decode-dsv4 -n metax-ai-pd` → 等 90s 连接清理 → `kubectl apply -k .../lws/`）。端口/bootstrap/host/metrics/JIT 等兼容修复由 pd-adapter §3.5 幂等补足，模型路径由新镜像内 models spec 决定，一般无需改脚本。

## 5. 部署

```bash
# 0) 前置: LWS CRD、InferencePool/EPP 已装（Helm 管理，本方案不包含）；模型已分发到全部候选节点
# 1) 节点标签 (hostNetwork 端口冲突, 各角色节点互斥; 当前实际分配)
kubectl label node mxgpu-1-147 mxgpu-1-154 mxgpu-1-165 mxgpu-1-166 metax-sglang-pd-prefill-dsv4=true --overwrite
kubectl label node mxgpu-1-152 mxgpu-1-167 mxgpu-1-168 mxgpu-1-169 metax-sglang-pd-decode-dsv4=true --overwrite
# 2) 部署
oc apply -k guides/pd-disaggregation/modelserver/gpu/sglang/metax/deepseek-v4-flash/lws/
```

## 6. 运行时 workaround（由 pd-adapter.sh §3.5 幂等应用，Pod 命令不再需要 sed/JIT 注入）

| 问题 | 处理 |
|------|------|
| §8.1 C500 JIT target 错误（`ErrorNoBinaryForGpu xcore1000`） | ✅ pd-adapter §3.5 启动时创建 nvcc→cucc wrapper（`.jit-wrapper` 标记幂等，镜像已内置则跳过）；pod 命令仅保留 `rm -rf /root/.cache/tvm-ffi` |
| §8.2 RDMA HCA 不符 | ✅ 镜像内 config.sh 已 patch `mlx5_0,mlx5_1` + env `NCCL_IB_HCA`/`MCCL_IB_HCA` |
| §8.3 C500 decode mem profile 缺失 | ✅ 0.5.12 镜像 models/deepseek-v4-flash.sh 已含 0.80/8,3 与 0.80/4,3 行（mtp=3 默认） |
| §8.4 Router CPU-only GPU probe | ✅ router.yaml pod 命令运行时 sed（镜像未内置此修复时应用；已内置时 pattern 无匹配自动跳过） |
| RC bootstrap 7977 与 llm-d sidecar 不符 | ✅ pd-adapter §3.5 改为 **8998**（sglang 默认） |
| hostNetwork 健康检查 | ✅ pd-adapter §3.5 改为 `--host=0.0.0.0` |
| Metrics | ✅ pd-adapter §3.5 注入 `--enable-metrics`（已含则跳过） |
| 新旧代交接 MCCL/Gloo 连接污染（8-14/8-15 故障报告） | ✅ LWS spec 已加 pod 级 `terminationGracePeriodSeconds: 120`；探针放宽（liveness failureThreshold 5 / readiness timeout 10s） |

## 6.1 PD Smart Adapter（调参适配层，ConfigMap 挂载，不进镜像）

`pd-adapter-configmap.yaml` 以 ConfigMap 形式挂载到 `/workspace/llm-d/pd-adapter.sh`（只读），pod 命令只需一行 `bash /workspace/llm-d/pd-adapter.sh`。它**不修改镜像内 config.sh / prefill.sh / decode.sh / models/*.sh 源脚本**，在容器可写层做运行时 sed 回写，并打印启动摘要（拓扑 + 全部可调参数有效值 + Entry Addr + Final Call）。

**§3.5 llm-d 兼容修复（幂等自动应用，无需 env）**：prefill/decode 端口 8000/8200、PD bootstrap 8998、`--host=0.0.0.0`、`--enable-metrics`、C500 JIT nvcc wrapper —— 镜像未内置时自动补上；已内置时模式不匹配自动跳过，同一套脚本新旧镜像通用，无需按版本维护多套配置。

**换模型 / 换镜像的通用流程**：① 改 yaml `image` 字段 + （可选）`PD_MODEL_SPEC` env → 部署完成，无需改脚本（模型路径由镜像内 models spec 决定）。

**可调参数**（未设置则保持脚本内默认值）：

| env | 作用 | 默认 |
|-----|------|------|
| `SGLANG_CONTEXT_LENGTH` | 上下文长度（`--context-length`） | 132096 |
| `SGLANG_PREFILL_MAX_RUNNING_REQUESTS_PRE_BATCH` | prefill 批内最大请求数（GLM 故障二规避值 32） | 64 |
| `PD_CHUNKED_PREFILL_SIZE` | prefill 分块大小 | 4096 |
| `PD_PREFILL_PP_SIZE` | prefill 流水并行度（需 `get_pp_layer_partition` 有对应行） | 8 |
| `PD_DECODE_MAX_RUNNING_REQUESTS` | decode 最大运行请求数 | 40 |
| `PD_DECODE_MTP` | MTP/EAGLE 推测解码 draft tokens（**=1 关闭推测解码**，A/B 实验用） | 3 |
| `PD_DECODE_DP_SIZE` / `PD_DECODE_EP_SIZE` | decode 数据/专家并行度 | = tp_size |
| `SGLANG_DISAGGREGATION_QUEUE_SIZE` | PD 传输队列深度 | 8 |
| `SGLANG_DISAGGREGATION_THREAD_POOL_SIZE` | PD 线程池 | 24 |
| `SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT` | PD bootstrap 等待超时 | 6000 |

**调试**：`PD_DRY_RUN=1` 只打印摘要不拉起引擎（排障/验证用）。


## 7. 验收清单（2026-08-15 全部 PASS）

```bash
# 1) Pod 就绪: prefill 4×1/1 Ready, decode 4×2/2 Ready (modelserver + routing-proxy)
oc -n metax-ai-pd get pods -l 'llm-d.ai/guide=pd-disaggregation'

# 2) P/D health = 200
curl -s -o /dev/null -w "%{http_code}\n" http://<prefill-ip>:8000/health     # 4 个 prefill 节点
curl -s -o /dev/null -w "%{http_code}\n" http://<decode-ip>:8200/health      # 4 个 decode 节点

# 3) PD bootstrap 8998 = 200 (不能 timeout/refused)
curl -s -o /dev/null -w "%{http_code}\n" "http://<prefill-ip>:8998/route?prefill_dp_rank=-1&prefill_cp_rank=-1&target_tp_rank=-1&target_pp_rank=-1"

# 4) Metrics 有数据
curl -s http://<prefill-ip>:8000/metrics | grep -v '^#' | wc -l    # > 0
curl -s http://<decode-ip>:8200/metrics  | grep -v '^#' | wc -l    # > 0

# 5) EPP 发现 8 个端点 (prefill-dsv4-{0..3}-rank-0 / decode-dsv4-{0..3}-rank-0)
oc -n metax-ai-pd logs deploy/pd-disaggregation-epp -c epp | grep -oE '"endpoint":"metax-ai-pd/[a-z0-9-]+-rank-0"'

# 6) 端到端 (完整链路: EPP + sidecar + Prefill + bootstrap + RDMA KV + Decode)
curl -s --max-time 120 -X POST http://pd-disaggregation-epp.metax-ai-pd.svc:80/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8","messages":[{"role":"user","content":"请只回复 OK"}],"max_tokens":16,"temperature":0}'
# 期望: choices[0].message.content == "OK"
```

## 8. 排障记录（本次部署踩坑）

| 现象 | 根因 | 修复 |
|------|------|------|
| prefill 启动 5 分钟后被杀（pool memory leak / sigquit） | RC 镜像 C500 JIT target 错误导致 dynamic chunking profiling 失败 → 内存池"泄漏"被 runtime checker 杀死 | §8.1 nvcc→cucc wrapper（见上） |
| decode warmup `/model_info` 404 → launch_server 被杀 → CrashLoop | **GLM 卸载遗漏**：`metax-sglang-pd` 命名空间的 `mx-sglang-pd-gateway-svc`（NodePort **30001**→8001）仍在，全节点 kube-proxy 把 :30001 DNAT 到 GLM 网关，劫持了 decode 的 warmup 自检和所有 30001 流量 | 删除遗留 gateway Deployment + Service（`oc -n metax-sglang-pd delete deploy gateway-pod svc mx-sglang-pd-gateway-svc`） |
| Router 启动即崩（`sdk_arch: unbound variable`） | vendor minilb.sh source utils.sh 在 CPU-only 节点无 GPU 检测 | 弃用 sglang router（本方案用 llm-d EPP 替代） |
| EPP 请求 500：`Decode handshake failed ... Aborted by AbortReq`，decode 反复查询 `prefill:8998` 被拒 | RC config.sh 显式 `--disaggregation-bootstrap-port=7977`，而 llm-d sidecar（kv-connector=sglang）按 sglang 默认 **8998** 查询 | 启动时 sed 将 bootstrap 改为 8998 |
| 跳板机 curl 任意节点 :30001 都返回 GLM 模型信息（幽灵 GLM） | 同上：GLM 网关 NodePort 30001 的网络级 DNAT 拦截 | 同上 |

## 9. 与 GLM 方案的差异

| 项 | GLM（metax/lws/） | 本方案（deepseek-v4-flash/lws/） |
|----|-------------------|---------------------------------|
| 模型 | GLM-5.1-W8A8 | DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8 |
| 镜像 | c500glmpd | 0.5.12-dsv4 |
| LWS 拓扑 | 1 replica × size=4（单实例 4 节点） | 4 replicas × size=1（4 个独立 1P1D 实例） |
| prefill 并行 | TP=8 PP=4 跨 4 节点 | TP=1 PP=8 单节点 |
| 网关 | EPP + routing-proxy sidecar | 同（llm-d 规范一致） |
| bootstrap | — | 8998（sglang 默认） |
| 启动脚本 | 宿主机 /opt/llm-launch-GLM5 | 镜像内 /workspace/llm-launch（RC 官方脚本） |
