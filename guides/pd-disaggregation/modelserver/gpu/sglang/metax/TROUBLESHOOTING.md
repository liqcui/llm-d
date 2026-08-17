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

## 5. MACA 沐曦环境变量补全

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

## 6. 镜像拉取策略

所有 Metax 配置的 `imagePullPolicy` 已统一为 `Always`，确保每次重启拉取最新镜像。
