# 沐曦 (MetaX) GPU PD 分离 — StatefulSet 部署指南

基于 `/opt/backup/k8s-sglang-pd/statefulset-mode` 生产验证配置，使用 K8s 原生 StatefulSet 在 8 台沐曦 C500/C600 GPU 节点上部署 4 Prefill + 4 Decode 的 PD 分离集群。

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
    ┌──────▼──────────┐           ┌────────▼───────────────┐
    │ Prefill STS      │           │ Decode STS             │
    │ 4 pods           │  NIXL KV  │ 4 pods                  │
    │                  │◄─(RDMA)──►│                          │
    │ pod-0:8000       │           │ pod-0 rp:8000→8200    │
    │ pod-1:8000       │           │ pod-1 rp:8000→8200    │
    │ pod-2:8000       │           │ pod-2 rp:8000→8200    │
    │ pod-3:8000       │           │ pod-3 rp:8000→8200    │
    │                  │           │                          │
    │ TP=8 PP=4 DP=1   │           │ TP=32 DP=32 EP=32      │
    │ 8 GPU/pod        │           │ 8 GPU/pod               │
    └──────────────────┘           └─────────────────────────┘
         4 物理节点                      4 物理节点
```

**请求流程：**

```
Client → EPP → routing-proxy(decode:8000) ──转发──→ prefill:8000   (1. Prefill)
                                            ←──KV元数据──
                                            ──转发──→ modelserver(decode:8200) (2. Decode)
                                            ←──tokens──
```

**Master IP 发现机制：**

- **Prefill**：`init-env` init container 通过 K8s API (`curl`) 获取 pod-0 的 `status.podIP`，写入 `/env-data/env.sh`
- **Decode**：主容器内置 K8s API 查询（避免 GPU 驱动二次初始化），端口改为 8200

**StatefulSet 额外资源：**

| 资源 | 作用 |
|------|------|
| `prefill-headless` Service | Prefill Pod DNS 发现 |
| `decode-headless` Service | Decode Pod DNS 发现 |
| `mx-sglang-pd-prefill-sa` | K8s API 认证 |
| `mx-sglang-pd-prefill-pod-reader` Role | `get pods` 权限 |
| `mx-sglang-pd-prefill-pod-reader-binding` RoleBinding | 绑定 SA |

---

## 2. 前置条件

### 2.1 节点标签

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

### 2.2 驱动与设备

```bash
# 每台沐曦节点确认
ls /opt/mxdriver    # MACA SDK
ls /dev/mxcd        # GPU CharDevice
ibstat mlx5_0       # KV Cache (NIXL)
ibstat mlx5_1       # DeepEP (Expert-Parallel)
```

### 2.3 模型数据

模型存放在每台节点的 `/data` 目录下。默认使用 `GLM-5.1-W8A8`（通过 `SGLang` 可调参数覆盖）。

### 2.4 旧部署清理

如果 namespace `metax-sglang-pd` 中有旧的 prefill/decode StatefulSet 在运行，需先清理避免 GPU 冲突：

```bash
kubectl -n metax-sglang-pd delete sts prefill-cluster-pod decode-cluster-pod --force --grace-period=0
```

---

## 3. 部署

### 3.1 前置条件

```bash
# 安装 LWS CRD（仅 LeaderWorkerSet 方式需要）
kubectl apply -f https://github.com/kubernetes-sigs/lws/releases/latest/download/manifests.yaml

# 创建 namespace
kubectl create ns metax-ai-pd --dry-run=client -o yaml | kubectl apply -f -

# 创建 HF Token secret
kubectl -n metax-ai-pd create secret generic llm-d-hf-token \
    --from-literal="HF_TOKEN=${HF_TOKEN}" --dry-run=client -o yaml | kubectl apply -f -
```

### 3.2 部署 llm-d Router

Router 是 PD 分离的调度核心，包含 EPP（Endpoint Picker）和内置 Envoy sidecar。**一个 Router 可以管理同 namespace 下的多个模型**，只要模型 Pod 带有匹配的 label。

```bash
helm install pd-disaggregation \
    ${ROUTER_STANDALONE_CHART} \
    -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
    -f ${REPO_ROOT}/guides/pd-disaggregation/router/pd-disaggregation.values.yaml \
    -n metax-ai-pd --version ${ROUTER_CHART_VERSION}
```

**验证 Router：**

```bash
# 确认 Service 已创建
kubectl -n metax-ai-pd get svc pd-disaggregation-epp

# 确认 Router Pod 运行
kubectl -n metax-ai-pd get pods -l llm-d-router-gateway=pd-disaggregation-epp
```

**Router 多模型架构：**

```
                        ┌──────────────────────────────────────┐
                        │   llm-d Router (EPP)                 │
                        │   namespace: metax-ai-pd              │
                        │                                      │
                        │   modelServers.matchLabels:           │
                        │     llm-d.ai/guide: "pd-disaggregation"│
                        │                                      │
                        │   EPP 插件链:                         │
                        │     prefill-filter / decode-filter   │
                        │     prefix-cache-scorer               │
                        │     queue-scorer / kv-cache-scorer   │
                        └──────────┬───────────────────────────┘
                                   │
            ┌──────────────────────┼──────────────────────┐
            │                      │                      │
       ┌────▼────────┐    ┌───────▼───────┐    ┌────────▼────────┐
       │ GLM-5.1-W8A8│    │ DeepSeek-R1   │    │ Qwen3.5-397B    │
       │ prefill ×4  │    │ prefill ×4    │    │ prefill ×4      │
       │ decode ×4   │    │ decode ×4     │    │ decode ×4       │
       │ labels:      │    │ labels:       │    │ labels:         │
       │  guide=pd-   │    │  guide=pd-    │    │  guide=pd-      │
       │  disaggregation│  │  disaggregation│  │  disaggregation  │
       │  role=prefill│    │  role=prefill │    │  role=prefill   │
       │  /decode     │    │  /decode      │    │  /decode        │
       └──────────────┘    └───────────────┘    └─────────────────┘
```

> **关键设计：** Router 通过 `llm-d.ai/guide: pd-disaggregation` + `llm-d.ai/role: prefill/decode` 标签**自动发现** Pod。只要新模型也打上相同 label，同一个 Router 就能统一调度，**无需为每个模型单独部署 Router**。仅当需要完全不同的调度策略时才需要额外的 Router。

### 3.3 部署 Model Server

#### LeaderWorkerSet 方式（推荐，llm-d 规范）

```bash
kubectl apply -n metax-ai-pd \
    -k ${REPO_ROOT}/guides/pd-disaggregation/modelserver/gpu/sglang/metax/lws/
```

**LWS 部署清单：**

| 资源 | 类型 | 数量 | 说明 |
|------|------|------|------|
| `mx-sglang-pd-lws` | ServiceAccount | 1 | LWS Pod 身份 |
| `prefill` | LeaderWorkerSet | replicas=1, size=4 | 4 pod, TP=8 PP=4, port 8000, 8 GPU/pod |
| `decode` | LeaderWorkerSet | replicas=1, size=4 | 4 pod, TP=32 DP=32 EP=32, port 8200, 8 GPU/pod |

#### StatefulSet 方式（备选，K8s 原生资源）

```bash
kubectl apply -n metax-ai-pd \
    -k ${REPO_ROOT}/guides/pd-disaggregation/modelserver/gpu/sglang/metax/multi-node/
```

**StatefulSet 部署清单：**

| 资源 | 类型 | 数量 | 说明 |
|------|------|------|------|
| `mx-sglang-pd-prefill-sa` | ServiceAccount | 1 | K8s API master IP 发现 |
| `mx-sglang-pd-prefill-pod-reader` | Role + RoleBinding | 2 | get pods RBAC |
| `prefill-headless` | Service | 1 | Prefill DNS, port 8000 |
| `decode-headless` | Service | 1 | Decode DNS, port 8200 |
| `prefill` | StatefulSet | 4 pods | TP=8 PP=4 DP=1, port 8000, 8 GPU/pod |
| `decode` | StatefulSet | 4 pods | TP=32 DP=32 EP=32 PP=1, port 8200, 8 GPU/pod |

### 3.4 验证部署

```bash
# 等待所有 Pod Ready
kubectl -n metax-ai-pd get pods -w

# 确认 Router
kubectl -n metax-ai-pd get pods -l llm-d-router-gateway=pd-disaggregation-epp

# 确认 Model Server（按角色）
kubectl -n metax-ai-pd get pods -l llm-d.ai/role=prefill
kubectl -n metax-ai-pd get pods -l llm-d.ai/role=decode
```

**发送测试请求：**

```bash
# 获取 EPP 地址
export IP=$(kubectl -n metax-ai-pd get service pd-disaggregation-epp -o jsonpath='{.spec.clusterIP}')

# 发送推理请求
curl -X POST http://${IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{"model": "glm-5.1-w8a8", "prompt": "你好"}' | jq
```

### 3.5 访问模式：Standalone vs Envoy Gateway

部署 PD 分离后，有两种方式访问推理服务：

#### Standalone 模式（默认，当前使用）

Router 内置 Envoy sidecar，直接通过 **EPP Service ClusterIP** 访问。无需额外部署 Gateway。

```
curl → EPP Service (ClusterIP)
        → Envoy sidecar (ext-proc → EPP 调度)
          → routing-proxy (decode pod :8000)
            → prefill:8000 (计算 KV Cache)
            → modelserver decode:8200 (自回归生成)
```

```bash
# 获取 EPP 地址
kubectl get svc pd-disaggregation-epp -n metax-ai-pd -o jsonpath='{.spec.clusterIP}'

# 集群内访问
curl -X POST http://${IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{"model": "glm-5.1-w8a8", "prompt": "你好"}'

# 如需集群外访问，暴露 EPP Service 为 NodePort 或 LoadBalancer
kubectl patch svc pd-disaggregation-epp -n metax-ai-pd \
    -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":8081}]}}'
```

#### Envoy AI Gateway 模式

使用 Kubernetes Gateway API + Envoy AI Gateway 作为统一入口，支持 HTTPRoute、流量策略等高级功能。

**流量路径：**

```
curl → Envoy AI Gateway (:80)
        → HTTPRoute → InferencePool
          → Envoy sidecar (ext-proc → EPP)
            → routing-proxy (decode pod :8000)
              → prefill → decode → response
```

**部署步骤：**

```bash
# 1. 安装 Gateway API Inference Extension CRDs
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml

# 2. 部署 Envoy AI Gateway
kubectl apply -k ${REPO_ROOT}/guides/recipes/gateway/envoy-ai-gateway/ -n metax-ai-pd

# 3. 卸载原有 standalone Router，用 Gateway 模式重新部署
helm uninstall pd-disaggregation -n metax-ai-pd

helm install pd-disaggregation \
    ${ROUTER_GATEWAY_CHART} \
    -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
    -f ${REPO_ROOT}/guides/recipes/router/features/httproute-flags.yaml \
    -f ${REPO_ROOT}/guides/pd-disaggregation/router/pd-disaggregation.values.yaml \
    --set provider.name=na \
    -n metax-ai-pd --version ${ROUTER_CHART_VERSION}

# 4. 获取 Gateway 地址并测试
export GW_IP=$(kubectl get gateway llm-d-inference-gateway -n metax-ai-pd \
    -o jsonpath='{.status.addresses[0].value}')

curl -X POST http://${GW_IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{"model": "glm-5.1-w8a8", "prompt": "你好"}'
```

**Gateway 模式关键配置文件：**

| 文件 | 作用 |
|------|------|
| `gateway/base/gateway.yaml` | 定义 `llm-d-inference-gateway`，监听端口 `80`，HTTP 协议 |
| `gateway/envoy-ai-gateway/gateway.yaml` | 指定 `gatewayClassName: envoy-ai-gateway` |
| `gateway/envoy-ai-gateway/client-traffic-policy.yaml` | Envoy buffer limit 从 32KB → 50MB（适配 AI 大 payload） |
| `router/features/httproute-flags.yaml` | 自动创建 HTTPRoute 连接 Gateway → InferencePool |

**两种模式对比：**

| 维度 | Standalone | Envoy AI Gateway |
|------|-----------|-----------------|
| 入口 | EPP Service ClusterIP | Gateway 统一入口 |
| 外部访问 | 需手动配 NodePort/LB | Gateway Controller 自动管理 |
| 高级路由 | 不支持 | HTTPRoute、流量拆分、重试策略 |
| 部署复杂度 | 低（helm install 一步） | 中（需先部署 Gateway CRDs + Gateway） |
| 适用场景 | 集群内测试、简单部署 | 生产环境、多租户、需要网关策略 |

---

## 4. llm-d 适配说明

### 4.1 标签体系

通过 `kustomization.yaml` 的 `labels` 配置注入到所有资源：

```yaml
llm-d.ai/guide: pd-disaggregation    # Router modelServers.matchLabels
llm-d.ai/role: prefill               # EPP prefill-filter 插件
llm-d.ai/role: decode                # EPP decode-filter 插件
llm-d.ai/model: glm-5.1-w8a8
llm-d.ai/engine-type: sglang
```

### 4.2 routing-proxy sidecar

- **位置**：decode StatefulSet 的 initContainer
- **模式**：`restartPolicy: Always`（K8s 1.28+ sidecar 模式）
- **端口**：8000（EPP 请求入口）→ 8200（modelserver）
- **KV 连接器**：`--kv-connector=sglang`

### 4.3 Prefill Pod 容器结构

| 容器 | 类型 | 说明 |
|------|------|------|
| `init-env` | Init (run once) | K8s API 查询 master IP → `/env-data/env.sh` |
| `modelserver` | Main | SGLang prefill server, port 8000 |

### 4.4 Decode Pod 容器结构

| 容器 | 类型 | 说明 |
|------|------|------|
| `routing-proxy` | Init (sidecar, restartPolicy=Always) | EPP 入口 port 8000, kv-connector=sglang |
| `modelserver` | Main | SGLang decode server, port 8200 |

### 4.5 与 LeaderWorkerSet 对比

| 维度 | StatefulSet | LeaderWorkerSet |
|------|-------------|----------------|
| Master IP 发现 | init container curl K8s API | LWS 自动注入 `LWS_LEADER_ADDRESS` |
| Rank 分配 | 从 hostname 提取 ordinal | LWS 自动注入 `LWS_WORKER_INDEX` |
| 额外资源 | headless Service ×2 + RBAC ×3 | LWS controller CRD |
| K8s 原生 | ✅ | 需安装 CRD |

---

## 5. 可调参数

通过 `kubectl set env` 动态调整：

```bash
# Prefill
kubectl -n metax-ai-pd set env sts/prefill \
    SGLANG_TP_SIZE=4 SGLANG_PP_SIZE=2 SGLANG_MEM_FRACTION_STATIC=0.85

# Decode
kubectl -n metax-ai-pd set env sts/decode \
    SGLANG_TP_SIZE=16 SGLANG_DP_SIZE=16 SGLANG_EP_SIZE=16
```

---

## 6. 排障

| 现象 | 原因 | 解决 |
|------|------|------|
| Pod Pending, `didn't match Pod's node affinity/selector` | 节点缺标签 | `kubectl label node <name> metax-sglang-pd-prefill\|decode=true` |
| Pod Pending, `didn't have free ports` | hostNetwork 端口冲突 | 检查 8000/30006/5000/5600，清理旧部署 |
| init-env CrashLoopBackOff | SA 缺 RBAC | `kubectl apply` rbac.yaml |
| `mxkwCreateQueueBlock timeout` (日志) | MACA 驱动初始化**正常瞬态** | 等待 2-5 分钟 |
| 旧 pod 占用 GPU | `metax-sglang-pd` namespace 残留 | 执行 [2.4 旧部署清理](#24-旧部署清理) |
| decode routing-proxy ImagePullBackOff | 镜像不可达 | 确认 `ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.9.0` 可拉取 |
| decode startup probe `connection refused` | 大模型加载中 | 正常，容忍 180 次失败 |
| prefill readiness `HTTP 404` | SGLang prefill 不暴露 `/v1/models` | 已配置 readiness 用 `/health` |
| decode readiness `HTTP 404` (LWS 模式) | SGLang decode server 同样不暴露 `/v1/models`，**LWS decode.yaml 中 readinessProbe 误用了 `/v1/models`** | `kubectl patch leaderworkerset decode` 将 path 改为 `/health`，同时修复源文件 `lws/base/decode.yaml`（详见 [6.3 Decode Readiness Probe 修复](#63-decode-readiness-probe-修复)） |
| `KVTransferError: Aborted by AbortReq` | prefill/decode 端口不一致或 `--host` 未绑定 `0.0.0.0`，导致 routing-proxy → prefill 连接失败 | 确保 prefill/decode 端口对齐 llm-d 标准、`--host=0.0.0.0`（详见 [6.4 端口对齐与网络配置](#64-端口对齐与网络配置)） |
| router 返回 `503 ServiceUnavailable` | Router pod 使用 Calico IP，bastion 无法访问 pod 网络 | Router 启用 hostNetwork + `--host=0.0.0.0`（详见 [6.4](#64-端口对齐与网络配置)） |
| Router pod `ContainerCreating` | `llm-d-router-disagg-sidecar` 或 `llm-d-router-endpoint-picker` 镜像缺失 | 从离线仓库加载镜像：`ctr -n k8s.io image import` |
| Webhook timeout: `failed calling webhook "mleaderworkerset.kb.io": context deadline exceeded` | 集群 DNS (CoreDNS/NodeLocalDNS) 未部署或节点 resolvconf 未更新，导致 API Server 无法通过 cluster DNS 解析 webhook service | 执行 `kubestack-offline.sh dns <cluster>` 部署 DNS 组件（详见 [6.1 DNS 部署与修复](#61-dns-部署与修复)） |
| LWS controller CrashLoopBackOff: `timed out waiting for cache to be synced` | DNS 不通导致 controller 无法连接 API Server 同步 informer 缓存 | 修复 DNS 后 `kubectl delete pod -n lws-system --all` 重建（详见 [6.1](#61-dns-部署与修复)） |
| `disaggregatedsets...is forbidden` (LWS controller 日志) | `lws-manager-role` 缺少 `disaggregatedset.x-k8s.io` 权限 | `kubectl patch clusterrole lws-manager-role` 添加权限（详见 [6.2 LWS RBAC 修复](#62-lws-rbac-修复)） |

### 6.1 DNS 部署与修复

**问题场景：** 集群缺少 CoreDNS/kube-dns Service/NodeLocalDNS，或节点 `systemd-resolved` 未配置 `cluster.local` 解析，导致：

- API Server 调用 webhook 超时：`context deadline exceeded`
- LWS controller 无法连接 API Server 同步 informer 缓存 → CrashLoopBackOff
- Pod 间 DNS 解析失败

**根因：** 节点 `/etc/resolv.conf` → `systemd-resolved` → 上游 DNS 服务器不识别 `cluster.local` 域名（如 `lws-webhook-service.lws-system.svc`）。

**修复步骤：**

```bash
# 方式 1：使用 kubestack-offline.sh（推荐）
./kubestack-offline.sh dns cubestack-cluster

# 方式 2：直接执行 ansible-playbook
ansible-playbook -i inventory/cubestack-cluster/hosts.yaml cluster.yml \
  --tags "coredns,nodelocaldns,resolvconf" \
  --become --become-user=root -v
```

**三个关键 tag：**

| Tag | 作用 |
|-----|------|
| `coredns` | 部署 CoreDNS Deployment、kube-dns Service、ConfigMap、RBAC |
| `nodelocaldns` | 部署 NodeLocalDNS DaemonSet（每节点缓存代理，监听 `169.254.25.10:53`） |
| `resolvconf` | 更新节点 `systemd-resolved` 配置，将 `cluster.local` 解析指向 NodeLocalDNS |

**验证 DNS 修复：**

```bash
# 从节点测试 cluster DNS 解析
resolvectl query lws-webhook-service.lws-system.svc.cluster.local
getent hosts lws-webhook-service.lws-system.svc.cluster.local

# 确认 systemd-resolved DNS 服务器包含 169.254.25.10
resolvectl status | grep -A 5 'DNS Servers'

# 确认 CoreDNS pods 运行
kubectl get pods -n kube-system -l k8s-app=kube-dns

# 确认 NodeLocalDNS pods 运行
kubectl get pods -n kube-system -l k8s-app=node-local-dns

# DNS 修复后删除 CrashLoop 中的 LWS pods 重建
kubectl delete pod -n lws-system --all
```

**DNS 数据流：**

```
Pod DNS 请求
  → /etc/resolv.conf (nameserver 169.254.25.10)
    → NodeLocalDNS (本地缓存)
      → cluster.local → CoreDNS (10.96.0.10)
      → 其他域名 → 上游 DNS (/etc/resolv.conf)
```

### 6.2 LWS RBAC 修复

**问题：** LWS controller 日志报 `cannot list resource "disaggregatedsets" in API group "disaggregatedset.x-k8s.io" at the cluster scope`，原因是 `lws-manager-role` ClusterRole 缺少 `disaggregatedset` 相关资源的权限。

**修复：**

```bash
kubectl patch clusterrole lws-manager-role --type='json' -p='[
  {
    "op": "add", "path": "/rules/-",
    "value": {
      "apiGroups": ["disaggregatedset.x-k8s.io"],
      "resources": ["disaggregatedsets"],
      "verbs": ["create","delete","get","list","patch","update","watch"]
    }
  },
  {
    "op": "add", "path": "/rules/-",
    "value": {
      "apiGroups": ["disaggregatedset.x-k8s.io"],
      "resources": ["disaggregatedsets/finalizers"],
      "verbs": ["update"]
    }
  },
  {
    "op": "add", "path": "/rules/-",
    "value": {
      "apiGroups": ["disaggregatedset.x-k8s.io"],
      "resources": ["disaggregatedsets/status"],
      "verbs": ["get","patch","update"]
    }
  }
]'
```

### 6.3 Decode Readiness Probe 修复

**问题：** LWS 模式下 decode pods 一直 `1/2 Running`，readiness probe 报 `HTTP probe failed with statuscode: 404`。

**根因：** `lws/base/decode.yaml` 中 decode 的 `readinessProbe` 配置为 `/v1/models`，但 SGLang decode server 不暴露此端点（不同于标准的 OpenAI-compatible API）。prefill 已正确配置为 `/health`，decode 需要同样修复。

**现象：**

```
Events:
  Warning  Unhealthy  Readiness probe failed: HTTP probe failed with statuscode: 404
```

**立即修复（不影响运行中的大模型加载进程）：**

```bash
# 修改 LWS 资源的 readinessProbe path
kubectl patch leaderworkerset decode -n metax-ai-pd --type='json' -p='[
  {"op": "replace", "path": "/spec/leaderWorkerTemplate/workerTemplate/spec/containers/0/readinessProbe/httpGet/path", "value": "/health"}
]'

# 删除 pods 让 LWS 用新配置重建（模型需重新加载，约 5-10 分钟）
kubectl delete pod -n metax-ai-pd decode-0 decode-0-1 decode-0-2 decode-0-3
```

**源文件修复：**

```bash
# 已在 lws/base/decode.yaml 中将 readinessProbe path 从 /v1/models 改为 /health
# kubectl apply 会覆盖修复后的配置
```

### 6.4 端口对齐与网络配置

**问题场景：** prefill/decode 端口与 llm-d 标准不匹配，或 `--host` 仅绑定节点 IP 而非 `0.0.0.0`，导致 routing-proxy 无法通过 `localhost` 连接同 pod 的 modelserver，也无法跨 pod 访问 prefill。

**llm-d LWS 端口标准：**

| 组件 | 端口 | 说明 |
|------|:---:|------|
| prefill modelserver | **8000** | SGLang prefill 服务端口 |
| decode routing-proxy | **8000** | EPP 入口，转发到 decode modelserver |
| decode modelserver | **8200** | SGLang decode 服务端口 |
| EPP InferencePool targetPorts | **8000** | EPP 统一路由端口 |

**关键修复（已应用到 `lws/base/decode.yaml` 和 `prefill.yaml`）：**

```bash
# decode: routing-proxy 端口 + modelserver 端口
sed -i 's/\(readonly \)\?decode_server_port=.*/readonly decode_server_port="8200"/' sglang/config.sh
# --vllm-port=8200 (routing-proxy arg)
# containerPort: 8200 (modelserver)

# prefill: modelserver 端口
sed -i 's/\(readonly \)\?prefill_server_port=.*/readonly prefill_server_port="8000"/' sglang/config.sh
# containerPort: 8000 (modelserver)

# 两端都需要: --host=0.0.0.0 (解决 hostNetwork 下 localhost 不通)
sed -i 's|--host="$local_ip"|--host=0.0.0.0|g' sglang/config.sh
```

**Router hostNetwork 配置：**

```bash
# Router 默认使用 Calico pod IP，在 bastion 上无法访问。
# 启用 hostNetwork 后直接通过节点 IP 访问：
kubectl -n metax-ai-pd patch deploy pd-disaggregation-epp -p \
    '{"spec":{"template":{"spec":{"hostNetwork":true}}}}'

# 访问地址变为: http://<router-node-ip>:8081
```

**EPP vs SGLang Default Gateway 对比：**

| 维度 | SGLang Default Gateway | llm-d EPP |
|------|----------------------|-----------|
| 负载均衡 | 简单轮询 | **多维度智能打分** |
| PD 分离感知 | ❌ 不理解 prefill/decode | ✅ prefill-filter / decode-filter 分别调度 |
| 前缀缓存 | ❌ 无感知 | ✅ prefix-cache-scorer，命中缓存优先 |
| KV Cache 利用率 | ❌ 无感知 | ✅ kv-cache-utilization-scorer，避让满载 |
| 队列深度 | ❌ 无感知 | ✅ queue-scorer，避让排队长的实例 |
| 活跃请求 | ❌ 无感知 | ✅ active-request-scorer，均衡负载 |
| 调度策略 | 单一 | 可组合：prefill 权重{prefix-cache:3, queue:2, kv-cache:2} |
| 协议 | HTTP 代理 | ext-proc (gRPC) + Envoy 深度集成 |
| 扩展性 | 硬编码 | 插件链，可自定义 scorer/filter/picker |

**完整请求流：**

```
curl → Router node:8081 (hostNetwork Envoy)
        → ext-proc → EPP (prefill + decode 双端打分)
          → routing-proxy (decode pod :8000)
            → prefill modelserver :8000 (计算 KV Cache, --host=0.0.0.0)
            → decode modelserver :8200 (NIXL/RDMA 拉取 KV, 自回归生成)
```
