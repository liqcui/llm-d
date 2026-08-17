# 沐曦 (MetaX) GPU PD 分离 — LeaderWorkerSet 部署指南

基于 llm-d `wide-ep-lws` 规范，使用 LeaderWorkerSet 在 8 台沐曦 C500/C600 GPU 节点上部署 4 Prefill + 4 Decode 的 PD 分离集群。

## 目录

- [1. 架构概览](#1-架构概览)
- [2. 前置条件](#2-前置条件)
- [3. 部署](#3-部署)
- [4. llm-d 适配说明](#4-llm-d-适配说明)
- [5. 可调参数](#5-可调参数)
- [6. 排障](#6-排障)

---

## 1. 架构概览

```
┌──────────────────────────────────────────────────────────┐
│                   llm-d Router (Helm)                     │
│  EPP: prefill-filter/decode-filter + prefix-cache-scorer │
│  matchLabels: llm-d.ai/guide=pd-disaggregation           │
└──────────┬───────────────────────────────┬───────────────┘
           │                               │
    ┌──────▼──────────┐           ┌────────▼───────────┐
    │ Prefill LWS      │           │ Decode LWS          │
    │ 1 replica × 4    │  NIXL KV  │ 1 replica × 4       │
    │                  │◄─(RDMA)──►│                      │
    │ pod-0:8000 (P0) │           │ pod-0 rp:8000→8200 │
    │ pod-1:8000 (P1) │           │ pod-1 rp:8000→8200 │
    │ pod-2:8000 (P2) │           │ pod-2 rp:8000→8200 │
    │ pod-3:8000 (P3) │           │ pod-3 rp:8000→8200 │
    │                  │           │                      │
    │ TP=8 PP=4 DP=1   │           │ TP=32 DP=32 EP=32   │
    │ 8 GPU/pod        │           │ 8 GPU/pod            │
    └──────────────────┘           └──────────────────────┘
         4 物理节点                      4 物理节点
```

**请求流程：**

```
Client → EPP → routing-proxy(decode:8000) ──转发──→ prefill:8000   (1. Prefill)
                                            ←──KV元数据──
                                            ──转发──→ modelserver(decode:8200) (2. Decode)
                                            ←──tokens──
```

| 步骤 | 说明 |
|------|------|
| ① Prefill | EPP 发给 decode pod 的 routing-proxy(8000)，转发到 prefill:8000 处理 prompt，返回 KV Cache 元数据 |
| ② Decode | routing-proxy 将元数据交给同 pod modelserver(8200)，通过 NIXL/RDMA(mlx5_0) 拉取 KV Cache，自回归生成 |

**LWS 自动注入的环境变量：**

| LWS 变量 | 映射到 SGLang 参数 | 示例值 |
|----------|-------------------|--------|
| `LWS_WORKER_INDEX` | `--node-rank` | 0, 1, 2, 3 |
| `LWS_LEADER_ADDRESS` | `--dist-init-addr` (提取 host) | `prefill-0.prefill-headless...` |
| `LWS_GROUP_SIZE` | `--nnodes` | 4 |

**为什么只有 decode 需要 routing-proxy？**

- **routing-proxy** = PD 调度中枢：接收 EPP 请求 → 转发给 prefill → 管理 KV 连接 → 回传 tokens
- **prefill** = 纯计算节点：被动接收请求 → 算 KV Cache → 返回元数据，不需要路由

---

## 2. 前置条件

### 2.1 安装 LWS Controller

```bash
kubectl apply -f https://github.com/kubernetes-sigs/lws/releases/latest/download/manifests.yaml --server-side
```

### 2.2 节点标签

```bash
# Prefill 节点 (4 台)
kubectl label node mxgpu-1-147 mxgpu-1-152 mxgpu-1-154 mxgpu-1-165 \
    metax-sglang-pd-prefill=true --overwrite

# Decode 节点 (4 台)
kubectl label node mxgpu-1-166 mxgpu-1-167 mxgpu-1-168 mxgpu-1-169 \
    metax-sglang-pd-decode=true --overwrite

# 验证
kubectl get nodes -l metax-sglang-pd-prefill=true
kubectl get nodes -l metax-sglang-pd-decode=true
```

### 2.3 驱动与设备

```bash
# 每台沐曦节点确认
ls /opt/mxdriver    # MACA SDK 驱动
ls /dev/mxcd        # GPU 设备
ibstat mlx5_0       # KV Cache 传输 (NIXL)
ibstat mlx5_1       # Expert-Parallel 通信 (DeepEP)
```

### 2.4 模型数据

模型存放在每台节点的 `/data` 目录下。默认使用 `GLM-5.1-W8A8`，可通过 `MODEL_PATH` 环境变量覆盖。

---

## 3. 部署

```bash
# 1. 创建 namespace
kubectl create ns metax-ai-pd --dry-run=client -o yaml | kubectl apply -f -

# 2. 创建 HF Token secret
kubectl -n metax-ai-pd create secret generic llm-d-hf-token \
    --from-literal="HF_TOKEN=${HF_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -

# 3. 部署 llm-d Router (Helm)
helm install pd-disaggregation \
    ${ROUTER_STANDALONE_CHART} \
    -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
    -f ${REPO_ROOT}/guides/pd-disaggregation/router/pd-disaggregation.values.yaml \
    -n metax-ai-pd --version ${ROUTER_CHART_VERSION}

# 4. 部署沐曦 Model Server (LWS)
kubectl apply -n metax-ai-pd \
    -k ${REPO_ROOT}/guides/pd-disaggregation/modelserver/gpu/sglang/metax/lws/
```

**部署清单：**

| 资源 | 类型 | 数量 | 说明 |
|------|------|------|------|
| `mx-sglang-pd-lws` | ServiceAccount | 1 | LWS Pod 身份 |
| `prefill` | LeaderWorkerSet | 4 pods (1×4) | TP=8 PP=4 DP=1, port=8000, 8 GPU/pod |
| `decode` | LeaderWorkerSet | 4 pods (1×4) | TP=32 DP=32 EP=32 PP=1, port=8200, 8 GPU/pod |

**验证：**

```bash
# 等待所有 Pod Ready（decode 大模型加载需要 5-10 分钟）
kubectl -n metax-ai-pd get pods -w

# 获取 EPP 地址
export IP=$(kubectl -n metax-ai-pd get service pd-disaggregation-epp -o jsonpath='{.spec.clusterIP}')

# 发送测试请求
curl -X POST http://${IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{"model": "glm-5.1-w8a8", "prompt": "你好"}' | jq
```

---

## 4. llm-d 适配说明

### 4.1 标签体系

通过 `base/kustomization.yaml` 的 `fields` 配置，标签被注入到 LWS CRD 的两层路径：

```yaml
# LWS 元数据层 — Router modelServers.matchLabels 发现
metadata/labels:
  llm-d.ai/guide: pd-disaggregation

# Worker Template 层 — EPP prefill-filter/decode-filter 筛选
spec/leaderWorkerTemplate/workerTemplate/metadata/labels:
  llm-d.ai/role: prefill          # 或 decode
  llm-d.ai/model: glm-5.1-w8a8
  llm-d.ai/engine-type: sglang
  llm-d.ai/guide: pd-disaggregation
```

### 4.2 routing-proxy sidecar

- **位置**：decode LWS 的 initContainer
- **模式**：`restartPolicy: Always`（K8s 1.28+ sidecar 模式）
- **端口**：8000（EPP 请求入口）→ 8200（modelserver）
- **KV 连接器**：`--kv-connector=sglang`

### 4.3 与 LWS 对比 StatefulSet

| 维度 | LeaderWorkerSet | StatefulSet |
|------|----------------|-------------|
| Master IP 发现 | LWS 自动注入 `LWS_LEADER_ADDRESS` | init container curl K8s API |
| Rank 分配 | LWS 自动注入 `LWS_WORKER_INDEX` | 从 hostname 提取 ordinal |
| 额外资源 | LWS controller CRD | headless Service ×2 + RBAC ×3 |
| 与 llm-d 一致 | ✅ (同 wide-ep-lws 模式) | — |

---

## 5. 可调参数

通过 `kubectl set env` 动态调整，无需重建 Pod：

```bash
# Prefill
kubectl -n metax-ai-pd set env lws/prefill \
    SGLANG_TP_SIZE=4 SGLANG_PP_SIZE=2 SGLANG_MEM_FRACTION_STATIC=0.85

# Decode
kubectl -n metax-ai-pd set env lws/decode \
    SGLANG_TP_SIZE=16 SGLANG_DP_SIZE=16 SGLANG_EP_SIZE=16 SGLANG_MEM_FRACTION_STATIC=0.82

# 切换模型
kubectl -n metax-ai-pd set env lws/prefill MODEL_PATH=/workspace/data/DeepSeek-R1-W8A8
kubectl -n metax-ai-pd set env lws/decode MODEL_PATH=/workspace/data/DeepSeek-R1-W8A8
```

---

## 6. 排障

| 现象 | 原因 | 解决 |
|------|------|------|
| Pod Pending, `didn't match Pod's node affinity/selector` | 节点缺标签 | `kubectl label node <name> metax-sglang-pd-prefill\|decode=true` |
| Pod Pending, `didn't have free ports` | hostNetwork 端口冲突 | 检查 8000/8200/5000/5600 是否被占用 |
| `mxkwCreateQueueBlock timeout` (日志) | MACA 驱动初始化**正常瞬态** | 等待 2-5 分钟自动消失 |
| decode startup probe `connection refused` | 大模型加载中 | 正常，startup probe 容忍 180 次失败（约 90 分钟） |
| prefill readiness `HTTP 404` | SGLang prefill 模式不暴露 `/v1/models` | 已配置 readiness 用 `/health` |
| routing-proxy ImagePullBackOff | 镜像 `ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.9.0` 不可达 | 检查集群网络或使用私有镜像仓库 |
| `kubectl apply -k .../lws/` 报错 `failed calling webhook "mleaderworkerset.kb.io": context deadline exceeded` | LWS webhook service (`lws-webhook-service.lws-system.svc:443`) 不可达 — Calico pod 网络路由问题，API server / Pod 无法连接到 webhook pod 的 9443 端口 | **临时绕过**: 将 webhook 的 `failurePolicy` 设为 `Ignore`（见下方 [6.1 Webhook 超时绕过](#61-webhook-超时绕过)） |
| LWS 创建成功但 Pod 始终不出现，controller 日志出现 `panic: runtime error: invalid memory address or nil pointer dereference` in `rollingUpdateParameters` | LWS v0.9.0 controller 的已知 bug，reconcile 时在 `leaderworkerset_controller.go:287` 发生空指针解引用 | v0.9.0 镜像有 bug 且集群无外网无法拉取其他版本。**两种方案**:<br>① 将 LWS v0.10.0+ 镜像推送到集群内私有 registry<br>② 改用 **StatefulSet 方式部署**（见 `README.metax-sts.md`） |

### 6.1 Webhook 超时绕过

当集群 Calico pod 网络无法路由到 `lws-webhook-service` 时，需临时将 LWS 相关 webhook 的 `failurePolicy` 设为 `Ignore`，部署完 LWS 资源后恢复。

```bash
# 1. 将所有 LWS webhook 设为 Ignore（5 个 webhook）
kubectl patch mutatingwebhookconfiguration lws-mutating-webhook-configuration --type='json' \
  -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Ignore"},
       {"op": "replace", "path": "/webhooks/1/failurePolicy", "value": "Ignore"}]'

kubectl patch validatingwebhookconfiguration lws-validating-webhook-configuration --type='json' \
  -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Ignore"},
       {"op": "replace", "path": "/webhooks/1/failurePolicy", "value": "Ignore"},
       {"op": "replace", "path": "/webhooks/2/failurePolicy", "value": "Ignore"}]'

# 2. 部署 LWS 资源（webhook 被绕过，LWS CR 可正常创建）
kubectl apply -n metax-ai-pd \
  -k ${REPO_ROOT}/guides/pd-disaggregation/modelserver/gpu/sglang/metax/lws/

# 3. 恢复所有 webhook 为 Fail
kubectl patch mutatingwebhookconfiguration lws-mutating-webhook-configuration --type='json' \
  -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Fail"},
       {"op": "replace", "path": "/webhooks/1/failurePolicy", "value": "Fail"}]'

kubectl patch validatingwebhookconfiguration lws-validating-webhook-configuration --type='json' \
  -p='[{"op": "replace", "path": "/webhooks/0/failurePolicy", "value": "Fail"},
       {"op": "replace", "path": "/webhooks/1/failurePolicy", "value": "Fail"},
       {"op": "replace", "path": "/webhooks/2/failurePolicy", "value": "Fail"}]'
```

> **注意**: 此绕过仅解决 `kubectl apply` 阶段 webhook 超时问题。若集群运行 **LWS v0.9.0**，controller 存在 nil pointer dereference bug，Pod 仍无法创建。需升级 LWS 或改用 StatefulSet 方式。
