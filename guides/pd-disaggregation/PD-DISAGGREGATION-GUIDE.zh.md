# 在 llm-d 中部署 Prefill/Decode 分离（PD 分离）

## 目录

- [1. 概述](#1-概述)
- [2. PD 分离架构](#2-pd-分离架构)
- [3. 适用场景与调优策略](#3-适用场景与调优策略)
- [4. 支持的后端](#4-支持的后端)
- [5. 前提条件](#5-前提条件)
- [6. 部署步骤](#6-部署步骤)
  - [6.1 部署 llm-d Router](#61-部署-llm-d-router)
  - [6.2 部署 Model Server](#62-部署-model-server)
  - [6.3 启用监控（可选）](#63-启用监控可选)
- [7. 配置详解](#7-配置详解)
  - [7.1 Router 插件链](#71-router-插件链)
  - [7.2 Prefill 实例配置](#72-prefill-实例配置)
  - [7.3 Decode 实例配置](#73-decode-实例配置)
  - [7.4 异构并行策略](#74-异构并行策略)
  - [7.5 KV 传输机制](#75-kv-传输机制)
- [8. 验证部署](#8-验证部署)
- [9. 基准测试](#9-基准测试)
- [10. 与聚合部署的性能对比](#10-与聚合部署的性能对比)
- [11. 清理](#11-清理)
- [12. 多后端配置参考](#12-多后端配置参考)

---

## 1. 概述

大语言模型（LLM）推理包含两个计算特征截然不同的阶段：

| 阶段 | 描述 | 瓶颈 |
|------|------|------|
| **Prefill（预填充）** | 一次性处理整个输入 prompt，生成 KV Cache | **计算密集型**，受 GPU FLOPS 限制 |
| **Decode（解码）** | 逐 token 生成输出，依赖 KV Cache | **内存带宽密集型**，受 HBM 到片上内存的传输速度限制 |

**PD 分离（Prefill/Decode Disaggregation）** 将这两个阶段拆分到独立的实例上运行，带来以下收益：

- **更高吞吐**：Prefill 和 Decode 实例各自针对不同的工作负载特征进行专业化配置
- **更好的服务质量**：长上下文的 Prefill 不再阻塞 Decode，降低 token 间延迟（ITL）
- **更高 GPU 利用率**：通过降低模型副本数（更宽的并行度），增加 KV Cache 可用内存

本指南以部署 `openai/gpt-oss-120b` 为例，展示如何在 llm-d 中完成 PD 分离部署。示例配置为：

- **8 个 Prefill 实例**，每个 `TP=1`
- **2 个 Decode 实例**，每个 `TP=4`

> llm-d 的 PD 分离能力原生内置于 Router（EPP）中，可以与前缀缓存路由、负载感知路由等特性自由组合。

---

## 2. PD 分离架构

```
                          ┌─────────────┐
                          │   客户端     │
                          └──────┬──────┘
                                 │ HTTP/gRPC
                          ┌──────▼──────┐
                          │   Proxy     │  (Envoy / Gateway)
                          └──────┬──────┘
                                 │ ext-proc
                          ┌──────▼──────┐
                          │    EPP      │  (Endpoint Picker)
                          │  调度引擎    │
                          └──────┬──────┘
                                 │
                  ┌──────────────┼──────────────┐
                  │                             │
           ┌──────▼──────┐              ┌──────▼──────┐
           │  Prefill    │   KV Cache   │   Decode    │
           │  Instance   │───(RDMA)────►│  Instance   │
           │  TP=1 x8    │   NIXL      │  TP=4 x2    │
           └─────────────┘              └─────────────┘
```

**请求流程：**

1. 请求到达 Proxy，Proxy 通过 `ext-proc` 协议向 EPP 请求调度决策
2. EPP 使用 PD 分离调度器，根据标签（`llm-d.ai/role=prefill/decode`）识别 Prefill 和 Decode 实例池
3. EPP 选择一个最优的 Prefill 实例和一个最优的 Decode 实例
4. 请求被路由到 Decode Pod 的 **routing-proxy sidecar**
5. Sidecar 将请求转发到 Prefill 实例进行处理
6. Prefill 完成后返回 KV block 元数据
7. Decode 实例通过 **NIXL over RDMA**（IB/RoCE/EFA）拉取 KV Cache
8. Decode 实例执行自回归生成

**关键组件：**

| 组件 | 作用 |
|------|------|
| **llm-d Router (EPP)** | 调度核心，负责 Prefill/Decode 的双端选择和打分 |
| **routing-proxy sidecar** | 运行在 Decode Pod 中，负责请求转发和 KV 连接管理 |
| **NIXL** | 高性能 KV Cache 传输库，支持 TCP 和 RDMA |
| **InferencePool** | 通过 label selector 管理所有 Model Server Pod |

---

## 3. 适用场景与调优策略

### 适用场景

PD 分离并非适用于所有负载。建议在以下条件下使用：

- **中大型模型**（如 `gpt-oss-120b`）
- **较长输入序列**（如 10k ISL / 1k OSL，而非 200 ISL / 200 OSL）
- **稀疏 MoE 架构**，有 wider-EP 的优化空间

### 调优关键参数

在调优 PD 分离部署时，重点关注以下参数：

1. **异构并行（Heterogeneous Parallelism）**
   - Prefill 实例：**较少并行度 + 较多副本**（如 TP=1 × 8 副本）—— Prefill 是计算密集型，更多副本可以并发处理更多请求
   - Decode 实例：**较多并行度 + 较少副本**（如 TP=4 × 2 副本）—— Decode 是内存带宽密集型，更高的 TP 可以增大 KV Cache 容量

2. **xPyD 比例**
   - 调整 Prefill 和 Decode 实例的数量比例，以匹配 ISL:OSL 的比值
   - 长输入、短输出 → 需要更多 Prefill 实例
   - 短输入、长输出 → 需要更多 Decode 实例

---

## 4. 支持的后端

| 后端 | 目录 | Notes |
|------|------|-------|
| **NVIDIA GPU (vLLM)** | `modelserver/gpu/vllm/` | vLLM，GKE nightly 测试 |
| **NVIDIA GPU (SGLang)** | `modelserver/gpu/sglang/` | SGLang，每次 release 验证 |
| **Google TPU v6e/v7x** | `modelserver/tpu/v6/vllm/` & `modelserver/tpu/v7/vllm/` | GKE TPU |
| **AMD GPU** | `modelserver/amd/vllm/` | 社区贡献 |
| **Intel XPU** | `modelserver/xpu/vllm/` | Intel Data Center GPU Max 1550+，社区贡献 |
| **Intel XPU + RDMA** | `modelserver/xpu/vllm-rdma/` | Intel XPU with RDMA via UCX |

**基础设施供应商支持（NVIDIA GPU）：**

| 供应商 | 目录 | 说明 |
|--------|------|------|
| **base** | `modelserver/gpu/vllm/base/` | 基础配置 |
| **GKE** | `modelserver/gpu/vllm/gke/` | 使用 DRA + DRANet (RoCE) |
| **CoreWeave** | `modelserver/gpu/vllm/coreweave/` | CoreWeave 云 |
| **AWS** | `modelserver/gpu/vllm/aws/` | AWS EFA 网络 |

---

## 5. 前提条件

### 环境准备

```bash
# 克隆仓库
export branch="release-0.8"
git clone https://github.com/llm-d/llm-d.git && cd llm-d && git checkout ${branch}

# 设置环境变量
export REPO_ROOT=$(realpath $(git rev-parse --show-toplevel))
source ${REPO_ROOT}/guides/env.sh
export GUIDE_NAME="pd-disaggregation"
export NAMESPACE="llm-d-pd-disaggregation"
export MODEL_NAME="openai/gpt-oss-120b"
```

### 安装 Gateway API Inference Extension CRDs

```bash
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api-inference-extension/releases/download/${GAIE_VERSION}/v1-manifests.yaml
```

### 创建命名空间

```bash
kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
```

### 创建 HuggingFace Token Secret

```bash
export HF_TOKEN=<your HuggingFace token>
kubectl create secret generic llm-d-hf-token \
    --from-literal="HF_TOKEN=${HF_TOKEN}" \
    --namespace "${NAMESPACE}" \
    --dry-run=client -o yaml | kubectl apply -f -
```

### GKE 集群预配置（DRA & RDMA/RoCE）

> 当前方案针对 **GKE A3/A4** 平台。DRANet（网络 DRA）需要支持 **Hairpin**（同节点直接环回传输）和 **Cross-rail**（跨节点多轨传输）路由，以确保 Prefill 和 Decode 节点之间的 KV Cache 交换正常。

请参考 [GKE Infrastructure Guide](../../docs/infra-providers/gke/README.md#gpu-dynamic-resource-allocation-dra-and-dranet-roce-on-gke) 完成集群、节点池、GPU DRA/网络 DRA 驱动的配置。

---

## 6. 部署步骤

### 6.1 部署 llm-d Router

Router 是 PD 分离的调度核心，包含 EPP（Endpoint Picker）和 Proxy sidecar。

#### Standalone 模式（推荐，默认使用内置 Envoy sidecar）

```bash
helm install ${GUIDE_NAME} \
    ${ROUTER_STANDALONE_CHART} \
    -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
    -f ${REPO_ROOT}/guides/${GUIDE_NAME}/router/${GUIDE_NAME}.values.yaml \
    -n ${NAMESPACE} --version ${ROUTER_CHART_VERSION}
```

#### Gateway 模式（使用 Kubernetes Gateway 管理 Proxy）

```bash
export PROVIDER_NAME=gke  # 可选: na, agentgateway, istio

helm install ${GUIDE_NAME} \
    ${ROUTER_GATEWAY_CHART}  \
    -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
    -f ${REPO_ROOT}/guides/recipes/router/features/httproute-flags.yaml \
    -f ${REPO_ROOT}/guides/${GUIDE_NAME}/router/${GUIDE_NAME}.values.yaml \
    --set provider.name=${PROVIDER_NAME} \
    -n ${NAMESPACE} --version ${ROUTER_CHART_VERSION}
```

> Gateway 模式需要先部署一个 Kubernetes Gateway，参考 [gateway guides](../../docs/infrastructure/gateway)。

#### Router 配置说明

Router 的核心配置文件通过 Helm values 注入：

```yaml
# 关键配置项（guides/pd-disaggregation/router/pd-disaggregation.values.yaml）
router:
  epp:
    pluginsConfigFile: "pd-config.yaml"  # 使用 PD 分离专用的插件配置
    pluginsCustomConfig:
      pd-config.yaml: |
        apiVersion: llm-d.ai/v1alpha1
        kind: EndpointPickerConfig
        plugins:
        - type: disagg-headers-handler       # 处理 PD 分离请求头
        - type: always-disagg-pd-decider      # 决策：始终启用 PD 分离
        - type: disagg-profile-handler        # 管理调度配置文件
        - type: prefill-filter                # 过滤：仅保留 Prefill 实例
        - type: decode-filter                 # 过滤：仅保留 Decode 实例
        - type: prefix-cache-scorer           # 打分：前缀缓存命中
        - type: queue-scorer                  # 打分：队列深度
        - type: kv-cache-utilization-scorer   # 打分：KV Cache 利用率
        - type: active-request-scorer         # 打分：活跃请求数

        schedulingProfiles:
        - name: prefill   # Prefill 阶段的调度策略
          plugins:
          - pluginRef: prefill-filter
          - pluginRef: prefix-cache-scorer
            weight: 3                        # 前缀缓存命中权重最高
          - pluginRef: queue-scorer
            weight: 2
          - pluginRef: kv-cache-utilization-scorer
            weight: 2

        - name: decode    # Decode 阶段的调度策略
          plugins:
          - pluginRef: decode-filter
          - pluginRef: active-request-scorer
            weight: 2
          - pluginRef: prefix-cache-scorer
            weight: 3                        # 前缀缓存命中权重最高

  modelServers:
    matchLabels:
      llm-d.ai/guide: "pd-disaggregation"   # 匹配 Model Server Pod 的标签
```

### 6.2 部署 Model Server

Model Server 使用 Kustomize overlay 部署，包含两个 Deployment：**prefill** 和 **decode**。

#### NVIDIA GPU + vLLM

```bash
# 选择基础设施供应商
export INFRA_PROVIDER=base  # base | coreweave | gke | aws

kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/gpu/vllm/${INFRA_PROVIDER}
```

#### NVIDIA GPU + SGLang

```bash
export INFRA_PROVIDER=base  # base | coreweave | gke

kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/gpu/sglang/${INFRA_PROVIDER}
```

> **SGLang vs vLLM 注意事项：**
>
> - SGLang 使用 `--disaggregation-mode={prefill,decode}` 和 `--disaggregation-transfer-backend=nixl`
> - Decode Pod 的 sidecar 配置为 `--kv-connector=sglang`
> - 每个 Prefill 实例运行一个 bootstrap server（端口 8998），用于 P/D 对等发现
> - SGLang 的 P/D 分离**仅在 NVIDIA GPU 上可用**，尚无 AMD/TPU 覆盖

#### Google TPU

```bash
# TPU v6e (Qwen/Qwen3-32B)
kubectl apply -n ${NAMESPACE} -k guides/${GUIDE_NAME}/modelserver/tpu/v6/vllm/

# TPU v7x (Qwen/Qwen3.5-397B-A17B-FP8)
kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/tpu/v7/vllm/
```

#### AMD GPU

```bash
kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/amd/vllm/base/
```

### 6.3 启用监控（可选）

```bash
# Router 侧：部署时添加监控配置
# helm install ... -f ${REPO_ROOT}/guides/recipes/router/features/monitoring.values.yaml

# Model Server 侧：部署 PD 专用监控资源
kubectl apply -n ${NAMESPACE} -k ${REPO_ROOT}/guides/recipes/modelserver/components/monitoring-pd
```

> 监控栈的安装请参考 [Monitoring stack setup](../../docs/operations/observability/setup.md)。

---

## 7. 配置详解

### 7.1 Router 插件链

llm-d EPP 的 PD 分离调度通过以下插件链实现：

```
请求进入 → disagg-headers-handler → always-disagg-pd-decider → disagg-profile-handler
                                                                        │
                                            ┌───────────────────────────┘
                                            ▼
                              ┌── prefill scheduling ──┐    ┌── decode scheduling ──┐
                              │ prefill-filter         │    │ decode-filter          │
                              │ prefix-cache-scorer    │    │ active-request-scorer  │
                              │ queue-scorer           │    │ prefix-cache-scorer    │
                              │ kv-cache-utilization   │    │                        │
                              └────────────────────────┘    └────────────────────────┘
```

| 插件 | 类型 | 功能 |
|------|------|------|
| `disagg-headers-handler` | 请求处理 | 处理 PD 分离相关的 HTTP 头部 |
| `always-disagg-pd-decider` | 决策 | 无条件启用 PD 分离（始终选择 Prefill + Decode 两端） |
| `disagg-profile-handler` | 配置 | 管理 prefill/decode 两个调度 profile |
| `prefill-filter` | 过滤 | 仅保留标签为 `llm-d.ai/role=prefill` 的 Pod |
| `decode-filter` | 过滤 | 仅保留标签为 `llm-d.ai/role=decode` 的 Pod |
| `prefix-cache-scorer` | 打分 | 根据前缀缓存命中情况对实例打分（权重 3，最高优先级） |
| `queue-scorer` | 打分 | 根据队列深度打分（权重 2） |
| `kv-cache-utilization-scorer` | 打分 | 根据 KV Cache 利用率打分（权重 2） |
| `active-request-scorer` | 打分 | 根据活跃请求数打分（权重 2） |

### 7.2 Prefill 实例配置

```yaml
# patch-prefill.yaml 核心配置
spec:
  replicas: 8                  # 8 个副本，高并发处理 Prefill
  template:
    spec:
      containers:
        - name: modelserver
          command: ["vllm", "serve"]
          args:
            - "openai/gpt-oss-120b"
            - "--tensor-parallel-size=1"        # TP=1，单 GPU，最大化并发
            - "--block-size=128"
            - "--kv-transfer-config"
            - '{"kv_connector":"NixlConnector", "kv_role":"kv_both"}'
            - "--no-disable-hybrid-kv-cache-manager"
          env:
            - name: VLLM_NIXL_SIDE_CHANNEL_HOST
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP       # 使用 Pod IP 作为 NIXL 侧通道地址
            - name: VLLM_HTTP_TIMEOUT_KEEP_ALIVE
              value: "120"                       # keep-alive >= sidecar idle timeout
          resources:
            limits:
              nvidia.com/gpu: "1"               # 每实例 1 GPU
              memory: 16Gi
              cpu: "8"
```

**配置要点：**
- `TP=1`：最小并行度，最大化副本数和并发处理能力
- `kv_role=kv_both`：同时作为 KV 生产者和消费者
- `VLLM_NIXL_SIDE_CHANNEL_HOST`：设置为 Pod IP，供 NIXL 侧通道通信使用
- 高副本数（8）：Prefill 是计算密集型，多副本可并发处理更多请求

### 7.3 Decode 实例配置

```yaml
# patch-decode.yaml 核心配置
spec:
  replicas: 2                  # 2 个副本
  template:
    spec:
      containers:
        - name: modelserver
          command: ["vllm", "serve"]
          args:
            - "openai/gpt-oss-120b"
            - "--tensor-parallel-size=4"        # TP=4，4 GPU 并行，增大 KV Cache
            - "--block-size=128"
            - "--kv-transfer-config"
            - '{"kv_connector":"NixlConnector", "kv_role":"kv_both"}'
            - "--no-disable-hybrid-kv-cache-manager"
            - "--port=8200"                     # 使用 8200 端口与 sidecar 区分
          resources:
            limits:
              nvidia.com/gpu: "4"               # 每实例 4 GPU
              memory: 64Gi
              cpu: "16"
```

**Decode sidecar 配置（由 base recipe 自动注入）：**

```yaml
# routing-proxy sidecar
initContainers:
  - name: routing-proxy
    args:
      - --port=8000            # sidecar 对外端口
      - --vllm-port=8200       # vLLM 模型服务端口
      - --kv-connector=nixlv2  # 使用 NIXL v2 连接器
      - --zap-log-level=1
      - --secure-proxy=false
```

**配置要点：**
- `TP=4`：较高并行度，增大每个实例的 KV Cache 容量（Decode 是内存密集型）
- `--port=8200`：vLLM 使用 8200 端口，sidecar 使用 8000 端口对外暴露
- routing-proxy sidecar 负责：请求转发到 Prefill、KV 连接管理
- 少副本数（2）：Decode 实例少但每个资源更多

### 7.4 异构并行策略

```
┌─────────────────────────────────────────────────────┐
│                   异构并行策略                        │
│                                                     │
│   Prefill (计算密集型)         Decode (内存密集型)    │
│   ┌─────┐ ┌─────┐ ┌─────┐    ┌───────────┐         │
│   │ TP1 │ │ TP1 │ │ TP1 │    │   TP=4    │         │
│   │ GPU │ │ GPU │ │ GPU │    │ 4×GPU     │         │
│   └─────┘ └─────┘ └─────┘    │ 大 KV Cache│        │
│   ... ×8 副本                └───────────┘         │
│                               ... ×2 副本           │
│                                                     │
│   总 GPU: 8×1 + 2×4 = 16 GPU                       │
└─────────────────────────────────────────────────────┘
```

这种策略的优势：
- Prefill 用单 GPU 多副本 → 并发处理多个 prompt
- Decode 用多 GPU 少副本 → 每个实例有更大的 KV Cache 可用空间
- 总体 GPU 数量相同时，PD 分离相比聚合部署可提升约 50% 的延迟性能

### 7.5 KV 传输机制

PD 分离的核心挑战在于 Prefill 和 Decode 之间的 KV Cache 传输。llm-d 使用 **NIXL** 作为传输层：

```
Prefill Pod                         Decode Pod
┌──────────┐                       ┌──────────────┐
│  vLLM    │                       │ routing-proxy│ (sidecar)
│  (Prefill)│                       │   :8000      │
│  :8000   │                       │       │       │
│  NIXL    │◄──── KV Cache ──────►│  NIXL │       │
│  :5600   │     (RDMA/TCP)        │       │       │
└──────────┘                       │   vLLM       │
                                   │  (Decode)    │
                                   │   :8200      │
                                   └──────────────┘
```

| 传输方式 | 说明 |
|----------|------|
| **NIXL over RDMA**（推荐） | 通过 InfiniBand / RoCE / EFA 实现高带宽、低延迟的 GPU-to-GPU 直接传输 |
| **NIXL over TCP** | 回退方案，适用于无 RDMA 网络的环境 |

**GKE 环境下的 RDMA 配置：**

GKE overlay 额外配置了 DRA（Dynamic Resource Allocation）和 DRANet：

```yaml
# GKE RDMA ResourceClaimTemplate
spec:
  spec:
    devices:
      requests:
      - name: gpu
        exactly:
          deviceClassName: gpu.nvidia.com
          count: 1
      - name: nic
        exactly:
          deviceClassName: mrdma.google.com
          count: 1
      constraints:
      - matchAttribute: "resource.kubernetes.io/pcieRoot"
```

同时设置环境变量：
```yaml
- name: UCX_IB_ROCE_REACHABILITY_MODE
  value: "all"   # 确保同节点和跨节点的 RoCE 可达性
```

---

## 8. 验证部署

### 获取 Proxy IP

**Standalone 模式：**

```bash
export IP=$(kubectl get service ${GUIDE_NAME}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')
```

**Gateway 模式：**

```bash
export IP=$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')
```

### 发送测试请求

```bash
kubectl run curl-debug --rm -it \
    --image=cfmanteiga/alpine-bash-curl-jq \
    --namespace="$NAMESPACE" \
    --env="IP=$IP" \
    --env="NAMESPACE=$NAMESPACE" \
    -- /bin/bash

# 在临时 Pod 内执行
curl -X POST http://${IP}/v1/completions \
    -H 'Content-Type: application/json' \
    -d '{
        "model": "openai/gpt-oss-120b",
        "prompt": "How are you today?"
    }' | jq
```

### 检查部署状态

```bash
# 查看 Router
kubectl get pods -n ${NAMESPACE} -l app.kubernetes.io/name=llm-d-router

# 查看 Model Server（Prefill 和 Decode）
kubectl get pods -n ${NAMESPACE} -l llm-d.ai/guide=pd-disaggregation

# 按角色查看
kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=prefill
kubectl get pods -n ${NAMESPACE} -l llm-d.ai/role=decode
```

---

## 9. 基准测试

llm-d 使用 [`llmdbenchmark`](https://github.com/llm-d/llm-d-benchmark) CLI 进行性能基准测试，底层使用 [`inference-perf`](https://github.com/kubernetes-sigs/inference-perf) 生成负载。

### 安装 Benchmark CLI

```bash
curl -sSL https://raw.githubusercontent.com/llm-d/llm-d-benchmark/main/install.sh | bash
cd llm-d-benchmark
source .venv/bin/activate
llmdbenchmark --version
```

### 设置 Endpoint

```bash
# Standalone 模式
export ENDPOINT_URL="http://$(kubectl get service ${GUIDE_NAME}-epp -n ${NAMESPACE} -o jsonpath='{.spec.clusterIP}')"
export GATEWAY_CLASS=epponly

# Gateway 模式
export ENDPOINT_URL="http://$(kubectl get gateway llm-d-inference-gateway -n ${NAMESPACE} -o jsonpath='{.status.addresses[0].value}')"
export GATEWAY_CLASS=istio
```

### 运行基准测试

```bash
# 高负载测试 (rate=45, 120s, 模拟生产负载)
llmdbenchmark \
    --spec           guides/pd-disaggregation \
    run \
    --endpoint-url   "${ENDPOINT_URL}" \
    --gateway-class  "${GATEWAY_CLASS}" \
    --model          "openai/gpt-oss-120b" \
    --namespace      "${NAMESPACE}" \
    --harness        inference-perf \
    --workload       guide_pd-disaggregation_1.yaml \
    --analyze

# 低负载延迟特征测试 (rate=1, 用于测量延迟分布)
llmdbenchmark \
    --spec           guides/pd-disaggregation \
    run \
    --endpoint-url   "${ENDPOINT_URL}" \
    --gateway-class  "${GATEWAY_CLASS}" \
    --model          "openai/gpt-oss-120b" \
    --namespace      "${NAMESPACE}" \
    --harness        inference-perf \
    --workload       guide_pd-disaggregation_2.yaml \
    --analyze
```

**工作负载说明：**
- `guide_pd-disaggregation_1.yaml`：**饱和负载**，rate=45, 45 workers, 每 worker 并发 100，用于测量吞吐和压力下的延迟
- `guide_pd-disaggregation_2.yaml`：**低负载延迟特征**，rate=1, 100 workers，用于测量延迟分布

---

## 10. 与聚合部署的性能对比

以下是 16×H200 GPU 上 `openai/gpt-oss-120b` 的 PD 分离 vs 聚合部署的对比数据（20:1 ISL:OSL, 45 QPS）：

| 指标 | 聚合部署 | llm-d PD 分离 | 改善 |
|------|----------|---------------|------|
| **E2E 延迟 (均值)** | 6.7s | 3.5s | **-47%** |
| **E2E 延迟 (P95)** | 10.2s | 5.08s | **-50%** |
| ITL (均值) | 25ms | 8ms | **-67%** |
| ITL (P95) | 197ms | 67ms | **-66%** |
| TTFT (均值) | 532ms | 1400ms | +170% |
| TTFT (P95) | 1574ms | 2471ms | +57% |

> **注意：** PD 分离会略微增加 TTFT（首 token 延迟），因为请求需要经过 Prefill → KV 传输 → Decode 的流程。但 E2E 延迟和 ITL（token 间延迟）大幅改善，因为 Decode 阶段不再受 Prefill 干扰。

**基准测试配置参考：**
- 8× Prefill (TP=1) + 2× Decode (TP=4)，共 16×H200
- 随机数据负载，ISL=5000, OSL=250
- 模型：`openai/gpt-oss-120b`

---

## 11. 清理

```bash
# 卸载 Router
helm uninstall ${GUIDE_NAME} -n ${NAMESPACE}

# 删除 Model Server（根据部署时选择的后端调整路径）
kubectl delete -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/gpu/vllm/${INFRA_PROVIDER}

# SGLang 部署的清理
kubectl delete -n ${NAMESPACE} -k ${REPO_ROOT}/guides/${GUIDE_NAME}/modelserver/gpu/sglang/${INFRA_PROVIDER}
```

---

## 12. 多后端配置参考

### 目录结构

```
guides/pd-disaggregation/
├── README.md                          # 主指南
├── README.tpu.md                      # TPU 专项指南
├── router/
│   └── pd-disaggregation.values.yaml  # Router PD 分离配置
├── benchmark-templates/
│   └── tpu.yaml                       # TPU 基准测试模板
├── baseline/
│   └── manifest.yaml                  # 聚合部署 baseline（用于对比测试）
└── modelserver/
    ├── components/
    │   └── gke-rdma/                  # GKE RDMA DRA 组件
    ├── gpu/
    │   ├── vllm/                      # NVIDIA GPU + vLLM
    │   │   ├── base/                  #   基础配置
    │   │   ├── gke/                   #   GKE overlay
    │   │   ├── aws/                   #   AWS overlay
    │   │   └── coreweave/             #   CoreWeave overlay
    │   └── sglang/                    # NVIDIA GPU + SGLang
    │       ├── base/
    │       ├── gke/
    │       ├── aws/
    │       └── metax/                 # 沐曦 C500/C600 GPU
    │           ├── kustomization.yaml # 单节点 overlay
    │           ├── patch-prefill.yaml
    │           ├── patch-decode.yaml
    │           └── multi-node/        # 4+4 多节点 StatefulSet overlay
    │               ├── kustomization.yaml
    │               ├── prefill-statefulset.yaml
    │               ├── decode-statefulset.yaml
    │               └── headless-services.yaml
    ├── tpu/
    │   ├── base/vllm/                 # TPU 基础配置
    │   ├── v6/vllm/                   # TPU v6e
    │   └── v7/vllm/                   # TPU v7x
    ├── amd/vllm/                      # AMD GPU
    │   ├── base/
    │   ├── oci/
    │   ├── tensorwave/
    │   └── amd-ci/
    └── xpu/
        ├── vllm/                      # Intel XPU
        └── vllm-rdma/                 # Intel XPU + RDMA
```

### 各后端关键差异

| 后端 | 模型 | Prefill 配置 | Decode 配置 | 特有网络配置 |
|------|------|-------------|-------------|-------------|
| **GPU vLLM (base)** | `gpt-oss-120b` | TP=1, 8 repl | TP=4, 2 repl | NIXL (TCP/RDMA) |
| **GPU SGLang (base)** | `gpt-oss-120b` | TP=1, 8 repl | TP=4, 2 repl | NIXL, bootstrap server |
| **GPU vLLM (GKE)** | `gpt-oss-120b` | TP=1, 8 repl + DRA | TP=4, 2 repl + DRA | DRANet (RoCE), UCX |
| **GPU vLLM (AWS)** | `gpt-oss-120b` | TP=1, 8 repl + EFA | TP=4, 2 repl + EFA | EFA (8 per Decode, 2 per Prefill) |
| **GPU vLLM (CoreWeave)** | `gpt-oss-120b` | TP=1, 8 repl | TP=4, 2 repl | RDMA IB |
| **TPU v6e** | `Qwen/Qwen3-32B` | 见具体配置 | TP=8 (2x4 topology) | ICI |
| **TPU v7x** | `Qwen/Qwen3.5-397B-A17B-FP8` | 见具体配置 | TP=8 (2x2x1 topology) | ICI |
| **AMD vLLM** | `Llama-3.3-70B-Instruct-FP8-KV` | 见具体配置 | 见具体配置 | ROCm |
| **沐曦 SGLang (单节点)** | `GLM-5.1-W8A8` | TP=4, PP=2, 2 repl | TP=8, DP=8, EP=8, 1 repl | IB/RoCE, MACA SDK |
| **沐曦 SGLang (4+4 多节点)** | `GLM-5.1-W8A8` | TP=8, PP=4, StatefulSet×4 | TP=32, DP=32, EP=32, StatefulSet×4 | IB/RoCE (mlx5_0/1), hostNetwork |

---

## 相关文档

- [PD 分离架构设计](../../docs/architecture/advanced/disaggregation/README.md)
- [vLLM PD 分离运维指南](../../docs/architecture/advanced/disaggregation/operations-vllm.md)
- [SGLang PD 分离运维指南](../../docs/architecture/advanced/disaggregation/operations-sglang.md)
- [基准测试详细说明](../../helpers/benchmark.md)
- [GKE 基础设施配置指南](../../docs/infra-providers/gke/README.md)
- [监控栈安装指南](../../docs/operations/observability/setup.md)
- [PD Disaggregation 论文参考](https://arxiv.org/html/2506.05508v1)

---

## 13. 沐曦 (MetaX) GPU 部署专项指南

> 详见独立部署文档：

- **[LeaderWorkerSet 部署指南](./README.metax-lws.md)**（推荐 — llm-d wide-ep-lws 规范，4 Prefill + 4 Decode）
- **[StatefulSet 部署指南](./README.metax-sts.md)**（备选 — K8s 原生资源，4 Prefill + 4 Decode）

```bash
# LWS 方式（推荐）
kubectl apply -n metax-ai-pd -k ${REPO_ROOT}/guides/pd-disaggregation/modelserver/gpu/sglang/metax/lws/

# StatefulSet 方式（备选）
kubectl apply -n metax-ai-pd -k ${REPO_ROOT}/guides/pd-disaggregation/modelserver/gpu/sglang/metax/multi-node/
```

### 13.1 前置条件

**安装 LWS CRD**（仅 LeaderWorkerSet 方式）：

```bash
kubectl apply -f https://github.com/kubernetes-sigs/lws/releases/latest/download/manifests.yaml
```

**节点标签（必须）：**

```bash
# Prefill 节点 (4 台)
kubectl label node mxgpu-1-147 mxgpu-1-152 mxgpu-1-154 mxgpu-1-165 metax-sglang-pd-prefill=true --overwrite
# Decode 节点 (4 台)
kubectl label node mxgpu-1-166 mxgpu-1-167 mxgpu-1-168 mxgpu-1-169 metax-sglang-pd-decode=true --overwrite
# 验证
kubectl get nodes -l metax-sglang-pd-prefill=true
kubectl get nodes -l metax-sglang-pd-decode=true
```

**驱动与设备：**

```bash
ls /opt/mxdriver   # MACA SDK 驱动目录
ls /dev/mxcd       # 沐曦 GPU 设备 (CharDevice)
```

**IB/RoCE 网络：**

```bash
ibstat mlx5_0    # KV Cache 传输 (NIXL)
ibstat mlx5_1    # Expert-Parallel 通信 (DeepEP)
```

### 13.2 部署

#### LeaderWorkerSet 方式（推荐）

```bash
# 1. 创建 namespace
kubectl create ns metax-ai-pd --dry-run=client -o yaml | kubectl apply -f -

# 2. 部署 llm-d Router (Helm)
helm install pd-disaggregation \
    ${ROUTER_STANDALONE_CHART} \
    -f ${REPO_ROOT}/guides/recipes/router/base.values.yaml \
    -f ${REPO_ROOT}/guides/pd-disaggregation/router/pd-disaggregation.values.yaml \
    -n metax-ai-pd --version ${ROUTER_CHART_VERSION}

# 3. 部署沐曦 LWS (Prefill ×4 + Decode ×4)
kubectl apply -n metax-ai-pd \
    -k ${REPO_ROOT}/guides/pd-disaggregation/modelserver/gpu/sglang/metax/lws/
```

**LWS 部署清单：**

| 资源 | 类型 | 数量 | 说明 |
|------|------|------|------|
| `mx-sglang-pd-lws` | ServiceAccount | 1 | LWS Pod 身份 |
| `prefill` | LeaderWorkerSet | replicas=1, size=4 | 4 pod, TP=8 PP=4, port 9292 |
| `decode` | LeaderWorkerSet | replicas=1, size=4 | 4 pod, TP=32 DP=32 EP=32, port 30006 |

#### StatefulSet 方式（备选）

```bash
kubectl apply -n metax-ai-pd \
    -k ${REPO_ROOT}/guides/pd-disaggregation/modelserver/gpu/sglang/metax/multi-node/
```

**StatefulSet 部署清单：**

| 资源 | 类型 | 数量 | 说明 |
|------|------|------|------|
| `mx-sglang-pd-prefill-sa` | SA | 1 | K8s API master 发现 |
| `mx-sglang-pd-prefill-pod-reader` | Role | 1 | get pods 权限 |
| `prefill-headless` | Service | 1 | DNS: port 9292 |
| `decode-headless` | Service | 1 | DNS: port 30006 |
| `prefill` | StatefulSet | 4 | TP=8 PP=4 DP=1, port 9292 |
| `decode` | StatefulSet | 4 | TP=32 DP=32 EP=32 PP=1, port 30006 |

**LWS vs StatefulSet 对比：**

| 维度 | LeaderWorkerSet | StatefulSet |
|------|----------------|-------------|
| Master IP 发现 | LWS 自动注入 `LWS_LEADER_ADDRESS` | init container curl K8s API |
| Rank 分配 | LWS 自动注入 `LWS_WORKER_INDEX` | 从 hostname 提取 ordinal |
| 额外资源 | LWS controller CRD | headless Service ×2 + RBAC ×3 |
| 与 llm-d 一致 | ✅ (同 wide-ep-lws 模式) | — |

### 13.3 llm-d 适配说明

**请求流程与 routing-proxy：**

```
Client → EPP → routing-proxy(decode:8000) ──转发──→ prefill:9292  (1. Prefill计算)
                                            ←──KV元数据──
                                            ──转发──→ modelserver(decode:30006) (2. Decode生成)
                                            ←──tokens──
```

| 步骤 | 说明 |
|------|------|
| Prefill | EPP 发给 decode pod 的 **routing-proxy sidecar**(port 8000)，sidecar 转发给 prefill 处理 prompt，返回 KV Cache 元数据 |
| Decode | sidecar 将元数据交给同 pod 的 modelserver(30006)，modelserver 通过 NIXL/RDMA 从 prefill 拉取 KV Cache 并自回归生成 |

**为什么只有 decode 需要 routing-proxy？**

- **routing-proxy** = PD 调度中枢：接收 EPP 请求 → 转发给 prefill → 管理 KV 连接 → 回传 tokens。EPP 只跟它通信。
- **prefill** = 纯计算节点：被动接收请求 → 算 KV Cache → 返回元数据。不需要路由，不需要 sidecar。

**Pod Labels（Router EPP 自动发现）：**

```yaml
llm-d.ai/guide: pd-disaggregation    # Router modelServers.matchLabels
llm-d.ai/role: prefill               # EPP prefill-filter 插件
llm-d.ai/role: decode                # EPP decode-filter 插件
```

**routing-proxy sidecar（decode pod）：**

- 作为 init container (restartPolicy: Always = sidecar 模式)
- 监听 port 8000，转发到 modelserver:30006
- `--kv-connector=sglang` — SGLang KV 连接器
- EPP 将 decode 请求路由到此 sidecar

**Master IP 发现（init-env container）：**

- pod-0：使用自身 `status.podIP`
- pod-1..3：通过 K8s API `GET /api/v1/namespaces/{ns}/pods/{name}` 查询 pod-0 IP
- 写入 `/env-data/env.sh`，主容器 `source` 加载

**Health Probes（EPP 探活和指标采集）：**

```yaml
startupProbe:  httpGet path=/health    port=modelserver
livenessProbe: httpGet path=/health    port=modelserver
readinessProbe: httpGet path=/v1/models port=modelserver
```

### 13.4 可调参数

通过 `kubectl set env` 动态调整，无需重建 Pod：

```bash
# Prefill 参数
kubectl -n metax-ai-pd set env sts/prefill \
    SGLANG_TP_SIZE=4 SGLANG_PP_SIZE=2 SGLANG_MEM_FRACTION_STATIC=0.85

# Decode 参数  
kubectl -n metax-ai-pd set env sts/decode \
    SGLANG_TP_SIZE=16 SGLANG_DP_SIZE=16 SGLANG_EP_SIZE=16

# 切换模型
kubectl -n metax-ai-pd set env sts/prefill MODEL_PATH=/workspace/data/DeepSeek-R1-W8A8
kubectl -n metax-ai-pd set env sts/decode MODEL_PATH=/workspace/data/DeepSeek-R1-W8A8
```

### 13.5 排障

| 现象 | 原因 | 解决 |
|------|------|------|
| Pod Pending, `didn't match Pod's node affinity/selector` | 节点缺标签 | 执行 13.1 节点标签命令 |
| Pod Pending, `didn't have free ports` | hostNetwork 端口冲突 | 检查 9292/30006/5000/5600 是否被占用 |
| init-env CrashLoopBackOff | SA 缺 RBAC | `kubectl apply` rbac.yaml |
| decode routing-proxy ImagePullBackOff | 镜像不可达 | 确认 `ghcr.io/llm-d/llm-d-router-disagg-sidecar:v0.9.0` 可拉取 |
| `mxkwCreateQueueBlock timeout` (日志) | MACA 驱动初始化 **正常瞬态** | 等待 2-5 分钟自动消失，不影响就绪 |

### 13.6 与 NVIDIA GPU 的关键差异

| 维度 | NVIDIA SGLang | 沐曦 SGLang |
|------|--------------|------------|
| 部署方式 | Deployment (kustomize) | **StatefulSet** (kustomize) |
| GPU 资源 | `nvidia.com/gpu` | `metax-tech.com/gpu` |
| SDK 路径 | `/usr/local/cuda` | `/opt/maca` + `CUDA_PATH=/opt/maca/tools/cu-bridge` |
| 网络 | overlay 网络 | hostNetwork + IB/RoCE |
| 服务端口 | Prefill=8000, Decode=8200 | **Prefill=9292, Decode=30006** |
| Pod 安全 | 默认 | privileged, runAsGroup=44 |
| 驱动挂载 | 无 | `/opt/mxdriver`, `/dev/mxcd`(CharDevice) |
| 镜像 | `lmsysorg/sglang` | `harbor.mycompany.com/metax/sglang:glmpd` |
| 模型 | `gpt-oss-120b` | `GLM-5.1-W8A8` / `DeepSeek-R1` / `Qwen3.5-397B` |
| 启动脚本 | 裸 `sglang.launch_server` | `bash sglang/prefill.sh` / `sglang/decode.sh` |
| Master 发现 | headless DNS | **K8s API** (curl + SA token) |
| 环境变量 | CUDA_*, NCCL_* | **双前缀**: CUDA_* + MACA_*, NCCL_* + MCCL_* |
| DeepEP | 可选 | 默认启用 `deepep + deep_gemm` |
| EPLB | 无 | 默认 `SGLANG_STATIC_EPLB=True` |
