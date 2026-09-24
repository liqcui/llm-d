# DeepSeek-V4 (rc3-maca) — PD 分离部署方案（沐曦 MetaX，LWS）

> 本目录是 DeepSeek-V4 在 **rc3-maca 镜像** 上的独立 PD 分离方案。
> 与 GLM 方案（`metax/lws/`）、DeepSeek-V4-Flash 方案（`metax/deepseek-v4-flash/`）互不覆盖，
> 三者使用**互斥的节点标签**，可在同一集群共存。

**状态**（2026-09-24，新集群实测）：
- ✅ **端到端已跑通**：prefill 4/4 + decode 4/4 Ready，EPP 已发现两端点，
  `Client → EPP → decode sidecar → prefill(KV) → decode` 返回正确结果（见 §7）。
- ⚠ **镜像已换为 `0.5.13-maca`（MACA 3.8.1.3）**，起因是新集群驱动栈
  （内核模块 3.9.6 + 用户态 3.8.1.3）与 rc3 镜像的 3.7.1.9 不匹配，decode 在
  CUDA graph 捕获期稳定报 `mcErrorIllegalAddress`（多节点复现，见 §13）。
- ⚠ **启动模式已切换为 `explicit`**：0.5.13 镜像不带厂商 `llm-launch` 脚本，
  只能显式拼装标准 `sglang.launch_server` argv（argv 按厂商 0.5.8-rc3 实测命令 1:1 翻译）。
- ⚠ **EAGLE/MTP 当前关闭**（`PD_SPECULATIVE_ENABLE=0`）：基础镜像的 EAGLE draft worker
  在抓图时崩溃（`_forward_shared_experts` 收到 None，属镜像内 bug，见 §13.5）。
  要恢复投机解码需换用带补丁的 adapter 镜像。
- 旧集群记录的"首个真实请求卡死"（原 §9）**在本轮未复现**；
  rc3 相关章节（§8/§9/§11）保留作为历史参考。

Router 连通性矩阵见 `TROUBLESHOOTING.md` §10；验收清单（含实测结果）见 §7。

---

## 1. 方案概览

| 项 | 值 |
|----|----|
| 模型 | `DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8`（宿主机 `/data/...`，hostPath 挂载到容器 `/workspace/data`） |
| 镜像 | `harbor.isuanova.com/metax/sglang:0.5.13-maca.ai3.8.1.3-torch2.10-py312-ubuntu22.04-amd64`（2026-09-24 由 rc3 镜像换为 0.5.13，见 §13） |
| 启动模式 | `explicit`（标准 `sglang.launch_server` argv；该镜像无厂商脚本） |
| 拓扑 | **每角色 1 个 4 节点逻辑实例**：LWS `replicas=1, size=4` → 4 pods / 4 节点 / 32 卡 |
| 并行度 | `tp=8 dp=4 ep=8`（4 节点各 1 个 DP replica），`pp=1` |
| 网关 | **双网关**：llm-d EPP（规范入口）+ sglang router（对比入口），同一套 4P+4D 后端 |
| 参数入口 | `base/prefill.yaml` / `base/decode.yaml` 的 `env:` 块（唯一入口） |

## 2. 架构

```
Client ──┬─→ EPP ──────────→ decode pod routing-proxy sidecar :8000
         │                        ├─ ① Prefill leg → prefill :8000 (worker-index=0)
         │                        │                   └─ RDMA KV (mlx5_0/1)
         │                        └─ ② Decode  leg → 同 pod modelserver :8200
         │
         └─→ sglang router :8001 ─→ 各实例 worker-index=0 的 :8000 / :8200
```

| 端口 | 组件 |
|------|------|
| 8000 | prefill HTTP（也是 decode 侧 routing-proxy sidecar 入口） |
| 8200 | decode modelserver |
| 8998 | prefill PD bootstrap（sglang 默认；llm-d sidecar 的 `kv-connector=sglang` 按此端口查询） |
| 5600 / 5000 | nixl KV 传输 / dist-init |

### ⚠ 仅 worker-index=0 是有效入口

`size=4` 时一个 LWS 组有 4 个 pod，但只有 **leader（worker-index=0）** 服务 HTTP；
其余 worker 的 HTTP 端口是残接口（`/server_info` 返回 404）。因此：

- `services.yaml` 的 selector 带 `leaderworkerset.sigs.k8s.io/worker-index: "0"`
- InferencePool 也必须按 `worker-index: "0"` 过滤（见 `TROUBLESHOOTING.md` §5）

若把 4 个 pod 全部发布，EPP 会把请求路由到不服务的 rank，表现为 decode handshake 失败。

## 3. 目录结构

```
deepseek-v4-rc3-maca/lws/
├── kustomization.yaml          # 部署入口 (namespace: metax-ai-pd; images: 集中覆盖镜像)
├── README.md
└── base/
    ├── prefill.yaml            # LWS prefill-dsv4rc3: replicas=1 size=4
    ├── decode.yaml             # LWS decode-dsv4rc3:  replicas=1 size=4 + routing-proxy sidecar
    ├── router.yaml             # sglang router Deployment (对比网关)
    ├── services.yaml           # prefill/decode headless (仅 worker-index=0)
    ├── serviceAccount.yaml
    └── launcher-configmap.yaml # 双模式启动器 (env → argv, 或调官方脚本)
```

## 4. 两种启动模式

由 `PD_LAUNCH_MODE` 选择，两者共用同一套拓扑解析与校验逻辑。

### `official`（默认）— 跑官方脚本 + 适配层

```bash
exec <llm-launch>/sglang/{prefill,decode}.sh <spec> <master> <nnodes> <rank>
```

**全部默认值来自厂商脚本**：显存 profile 表、EPLB 权重加载、版本相关 env（0.5.7/0.5.8/0.5.10
分支）、C500 JIT wrapper、网卡自动探测（`local_ip` / `net_primary_iface` / `gpu_name` /
`num_dies`）。

本层只做四件事（参考 GPUStack `start_pd.sh` 适配层）：

1. **拓扑注入**：LWS → `<spec> <master> <nnodes> <rank>`
2. **env → 厂商脚本变量回写**（下表）：`sed` 只改**容器可写层**，不动镜像
3. **Port / Host / Bootstrap 覆盖**
4. **启动摘要**：打印回写后的**有效值**（未回写的项按公式原样显示）

#### 回写参数表（改了才会生效；不设=保持厂商默认）

| env | 回写到 | 厂商默认（4 节点 × 8 卡） |
|-----|--------|--------------------------|
| `PD_TP_SIZE` / `PD_DP_SIZE` / `PD_EP_SIZE` / `PD_PP_SIZE` | config.sh `{decode,prefill}_{tp,dp,ep,pp}_size` | decode: **dp=ep=tp=32**, pp=1（attention_tp=1）<br>prefill: pp=8 → tp=4, dp=1 |
| `PD_MEM_FRACTION_STATIC` | config.sh `{role}_mem_fraction_static` | decode 查表 `(gpu,dp,mtp)`；prefill 硬编码 0.82<br>⚠ **表里没有本 GPU**，查空会传空串启动失败 |
| `PD_MODEL_PATH` | models/\<spec\>.sh `model_path_specific` | 厂商硬编码 `/bgfs/models/...` |
| `PD_CONTEXT_LENGTH` | models/\<spec\>.sh `context_length_specific` | 131072 |
| `PD_CHUNKED_PREFILL_SIZE` | models/\<spec\>.sh `chunked_prefill_size_default` | 4096 |
| `PD_SPECULATIVE_ENABLE=0` | models/\<spec\>.sh `decode_mtp_specific=1`（关 MTP） | — |
| `PD_SPECULATIVE_NUM_DRAFT_TOKENS` | models/\<spec\>.sh `decode_mtp_specific` | 4（→ `steps=3, topk=1`） |
| `PD_EPLB_ENABLE` / `PD_EPLB_FILE` | models/\<spec\>.sh `decode_eplb_file_specific` | 指向镜像内**不存在**的 `/workspace/eplb/...`，故默认回写空值=关闭 |
| `PD_HCA_LIST` / `PD_MOONCAKE_IB_DEVICE` | config.sh `hca_list` / `mooncake_ib_device` | `mlx5_bond_2..5` / `mlx5_bond_1`（本环境不适用）<br>`mooncake_ib_device` 同时是 `--disaggregation-ib-device`（config.sh:157） |
| `PD_ENABLE_METRICS=1` | 解锁 config.sh 中被注释的 `--enable-metrics` | 厂商默认注释（关闭） |
| `prefill_max_running_requests_pre_batch` /<br>`decode_max_running_requests_specific` | 厂商同名变量（GPUStack 同名约定） | 64 / 8（decode 侧是**每 DP rank**，官方脚本会 ×dp） |
| `PD_HTTP_PORT` / `PD_HOST` / `PD_BOOTSTRAP_PORT` | `{role}_server_port` / `--host` / bootstrap | 厂商 9292(prefill)/9293(decode) → 本项目 8000/8200 |

⚠ **official 模式会先清除 explicit 专用环境变量**（`USE_INDEX_CACHE`、
`USE_SINGLE_STREAM_DISPATCH_OVERLAP`、`SGLANG_DEEPEP_BF16_DISPATCH`、
`SGLANG_DSV4_FIX_TP_ATTN_A2A_SCATTER`、`MX_SGLANG_ENABLE_KV_LAYOUT_FIX` 及厂商自己
export 的网卡/架构变量），否则会覆盖厂商脚本决定的值 —— 名为对齐、实为偏离。
清单见 `launcher-configmap.yaml` 的 `_official_unset_explicit_envs()`。

### `explicit` — 绕过官方脚本（逃生舱）

由 `env` 显式拼装 `python3 -m sglang.launch_server` 的完整 argv，参数完全可控、可审计。
**代价**：厂商脚本负责的一切都要自己补齐，实测漏项就会走非验证路径：

| 官方脚本做的事 | 本方案如何处理 |
|----------------|----------------|
| 版本相关 env（0.5.7/0.5.8/0.5.10 分支） | ⚠ 手工判断，易漏（见 §5.3） |
| DSv4 行为开关 | ⚠ 靠 env 手工补（`models/deepseek-v4-flash.sh` 里那两条） |
| 网卡自动探测 + HCA 映射 | ⚠ 靠 `PD_SOCKET_IFNAME` / `PD_HCA_LIST` 手填 |
| 显存 profile 表 | ⚠ 用 `PD_MEM_FRACTION_STATIC` 显式给（见 §5.2） |
| EPLB 权重加载 | `PD_EPLB_ENABLE=1` + `PD_EPLB_FILE` |
| Port/Host/Bootstrap | env 直接生效 |
| 其他厂商特化 | 逃生舱 `PD_EXTRA_ARGS` |

切换方式：把 `PD_LAUNCH_MODE` 改成 `official` / `explicit` 即可，其余配置项沿用。

## 5. 可调参数

全部在 `base/prefill.yaml` 与 `base/decode.yaml` 的 `env:` 块中修改。

### 共用

| 变量 | 默认 | 说明 |
|------|------|------|
| `PD_LAUNCH_MODE` | `explicit` | `explicit` \| `official` |
| `PD_ROLE` | 分别固定 | `prefill` / `decode`，无需改 |
| `PD_MASTER_IP` | 空（**保持空**） | 留空=由 launcher 自动解析（rank0 用 POD_IP，rank1-3 查 K8s API 取 leader 真实 IP），见 §5.1 |
| `PD_MODEL_PATH` | `/workspace/data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8` | explicit 模式用 |
| `PD_SOCKET_IFNAME` | `auto` | `auto`=按默认路由自动探测（等价厂商 `get_net_primary_iface`）；**不要写死 manage0**——本集群 node 28 的 IP 在 br-lan 上（见 §13.2） |
| `PD_HCA_LIST` | `mlx5_0,mlx5_1` | 计算网卡，**按实际环境修改** |
| `PD_EXTRA_ARGS` | 空 | 自由追加 argv（仅 explicit），如 `--disable-radix-cache` |

### 5.1 ⚠ hostNetwork 与 dnsPolicy 的相互作用（部署前必读）

prefill / decode pod 均为 `hostNetwork: true` + `dnsPolicy: ClusterFirst`。

**`dnsPolicy: ClusterFirst` 在 `hostNetwork: true` 时会被 kubelet 忽略**，实际退化为
节点自身的 `resolv.conf`（等价 `Default`）—— 即 **集群 DNS 不可用**（`LWS_LEADER_ADDRESS`
这类 leader 域名解析不到）。因此 master 地址交给 `pd-launcher` 按以下优先级解析：

| 优先级 | 来源 | 说明 |
|--------|------|------|
| 1 | `PD_MASTER_IP`（env） | 显式覆盖。**默认留空**；只在排障时手填，且必须是宿主机 IP |
| 2 | rank0 自身 `POD_IP` | hostNetwork ⇒ podIP 即本节点 IP，正是 master |
| 3 | rank1-3 查 K8s API | 取 leader pod `<lws>-0` 的 `status.podIP`（真实宿主机 IP），最多重试 10×3s |
| 4 | DNS 回退 | `getent hosts <LWS_LEADER_ADDRESS>`，实测 NodeLocalDNS 下不可靠，仅兜底 |
| — | 都失败 | **直接 die**（不做「rank≠0 各自回退 POD_IP」的兜底：那样 4 个节点会各自成为 master，静默分裂比失败更危险） |

优先级 3 依赖 `rbac.yaml` 的 `mx-sglang-pd-pod-reader`（对 `pods` 的 `get`）。

> ⛔ **不要把 `services.yaml` 里 `*-dist-master` 的 ClusterIP 填进 `PD_MASTER_IP`**：
> decode 开了 `--enable-dp-attention`，sglang 会从 `--dist-init-addr` 推导出一个
> ZMQ 握手端点 `tcp://<host>:<port+13>`，要求其余节点**直连 node0 的真实 IP**；
> ClusterIP 在每台节点上都是本地地址（kube-ipvs0）且没有该端口的 IPVS 规则，
> 握手永远建不起来 → node0 阻塞、其余节点 600s 超时退出、整组无限重建。
> 实测：decode 永远卡在 `1/2`。根因分析见 `TROUBLESHOOTING.md` §12。
> 那两个 ClusterIP 的用途是**给客户端**（sglang 对比网关）做稳定入口，不是 dist-init。

### 结构

`PD_TP_SIZE`(8) `PD_PP_SIZE`(1) `PD_DP_SIZE`(4) `PD_EP_SIZE`(8)
`PD_HTTP_PORT`(P 8000 / D 8200) `PD_BOOTSTRAP_PORT`(8998) `PD_DIST_INIT_PORT`(5000)
`PD_DISAGG_IB_DEVICE`(mlx5_0,mlx5_1) `PD_CONTEXT_LENGTH`(200000) `PD_KV_CACHE_DTYPE`(bf16)

### 调优（当前取值 = 厂商默认 + 必要的本项目覆盖）

official 模式下这些值经 §4 回写表写进厂商脚本；下表是本方案 yaml 里**显式写死**的值
（其余一律不写 = 保持厂商默认，摘要里会原样显示厂商公式）：

| 变量 | prefill | decode | 说明 |
|------|---------|--------|------|
| `PD_TP_SIZE` / `PD_DP_SIZE` / `PD_EP_SIZE` / `PD_PP_SIZE` | 4 / 1 / — / 8 | 32 / 32 / 32 / 1 | 厂商公式 `nnodes×num_dies` 在 4 节点 ×8 卡下的结果（decode 即 attention_tp=1） |
| `PD_MEM_FRACTION_STATIC` | 0.82（厂商 prefill 恒为 0.82） | 0.82 ⚠ 起手值 | **decode 侧是硬约束**，见 §5.2，部署后必须实测校准 |
| `PD_CONTEXT_LENGTH` | 131072 | 131072 | 厂商 `context_length_specific`（原先本项目用 200000） |
| `PD_CHUNKED_PREFILL_SIZE` | 4096 | 4096 | 厂商 `chunked_prefill_size_default` |
| `PD_SPECULATIVE_ENABLE` / draft tokens | — | 1 / 4 | 厂商 `decode_mtp_specific=4`（→ steps=3, topk=1）；prefill 不跑投机解码 |
| `PD_HCA_LIST` / `PD_MOONCAKE_IB_DEVICE` | mlx5_0,mlx5_1 | 同左 | 厂商默认 `mlx5_bond_*`，本环境不适用 |
| `PD_ENABLE_METRICS` | 1 | 1 | 厂商 `--enable-metrics` 是注释状态，本项目解锁以便 Prometheus 采集 |
| `PD_EPLB_ENABLE` | — | 0 | 厂商默认 EPLB 文件路径在镜像内不存在 → 默认关闭 |

### 5.2 ⚠ decode `mem_fraction_static` 是硬约束，不是"越大越好"

本 fork 的 `ModelRunner.total_gpu_memory` = **该 worker init 时刻的可用显存**
（`model_runner.py:387` → `init_torch_distributed()` 返回 `min_per_gpu_memory`，非设备容量）。
EAGLE draft worker 在 target（含 ~8.2 GB cuda graph）之后才创建，因此必须满足：

```
draft init 时可用显存  >  draft 权重 / mem_fraction_static
```

dp=4 拓扑实测：f=0.82 时判据 2.90 GB、实测 2.86 GB → 启动即 `RuntimeError: Not enough
memory. Please try to increase --mem-fraction-static`（报错信息**误导**，调大只会更糟）。
每降 0.01 可给 draft 多留 ~0.6 GB、门槛只抬高 ~0.035 GB，dp=4 时取 0.78 才留出余量。

⚠ **本仓库当前切到的是厂商默认拓扑 dp=tp=ep=32（attention_tp=1），上面这组实测数字
（对应 dp=4）不能直接沿用**：0.82 只是起手值，部署后必须按判据校准 —— 看启动日志里
draft worker 的 `Load weight begin. avail mem=` 与 `Memory pool end. avail mem=`，
若 draft 阶段报 `Not enough memory` 就按 0.01 步长往下调。
**换 GPU / 换 dp / 换 MTP 档位都要重新标定** —— 厂商 `get_decode_mem_fraction_static()`
表按 `(gpu_name, dp_size, mtp)` 取值正是这个原因（且表里没有本 GPU 型号）。
详见 `TROUBLESHOOTING.md` §8。

### 5.3 ⚠ explicit 模式需要手工补齐的厂商环境变量（official 模式自动继承）

`official` 模式由厂商脚本自己 `export` 这些值，无需干预；切到 `explicit`（逃生舱）时
必须手工补齐，否则走非验证路径：

| 变量 | fork 默认 | 厂商 DSv4 取值 | 作用 / 生效条件 |
|------|-----------|----------------|-----------------|
| `SGLANG_DSV4_FIX_TP_ATTN_A2A_SCATTER` | `True` | `False` | 关闭 attention-TP 内的 A2A token 切分/all-gather（`deepseek_v4.py:1187`）<br>`models/deepseek-v4-flash.sh` **无条件** export |
| `MX_SGLANG_ENABLE_KV_LAYOUT_FIX` | 未设 | `False` | KV layout fix 开关（原生侧），同上无条件 export |
| `USE_SINGLE_STREAM_DISPATCH_OVERLAP` | 未设（=关） | `1` | MoE dispatch 走单流而非 alt_stream 双流 overlap（`deepseek_v2.py:646`，判"存在即真"）<br>⚠ config.sh 里是 **v0.5.7 专属分支**：本镜像为 0.5.8，厂商**并不设置** |
| `SGLANG_DEEPEP_BF16_DISPATCH` | `False` | `1` | 关掉 FP8 per-token-group quant dispatch（`deepep.py:440`）<br>同样仅 v0.5.7 分支 |

其余：EPLB 文件需 hostPath 挂载到镜像内不存在的 `/workspace/eplb/...`、显存 profile 表
（§5.2）、C500 JIT wrapper。厂商 `config.sh` 里 `USE_INDEX_CACHE=1` 是**注释掉**的，
本项目 explicit 模式默认打开 —— 排查请求卡死（§9）时值得优先怀疑。

### ⚠ 需要部署时确认的三处

| 变量 | 当前值 | 风险 |
|------|--------|------|
| `PD_MEM_FRACTION_STATIC`(decode) | 0.82 | 新拓扑（dp=32）下的起手值，**未实测**；按 §5.2 判据校准 |
| `PD_EPLB_ENABLE` | 0 | 官方路径无 EPLB 文件可用；要用需先挂载 `/workspace/eplb/...` 并置 1 |
| `PD_MASTER_IP` | 空（**保持空**） | 留空由 launcher 自动解析（rank0=POD_IP，rank1-3 查 K8s API 取 leader 真实 IP）。填值只用于排障，且**不能填 ClusterIP**（见 §5.1） |

### official 模式专用

`LLM_LAUNCH_DIR`(默认 `/workspace/llm-launch/sglang`) `PD_MODEL_SPEC`(默认 `deepseek-v4-flash`)
`SKIP_PORT_OVERRIDE` `SKIP_HOST_OVERRIDE` `SKIP_BOOTSTRAP_OVERRIDE`（置非空即跳过对应覆盖）

env 同名回写（留空=不改）：
`prefill_max_running_requests_pre_batch` / `decode_max_running_requests_specific` /
`decode_mtp_specific` / `decode_eplb_file_specific`

## 6. 部署

```bash
# 0) 前置: LWS CRD、Gateway API / GAIE CRD、InferencePool/EPP 已装;
#    模型已分发到全部 8 个候选节点 /data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8
#    (官方文档: GPU 驱动与 SDK ≥ 3.7.1, mx-smi 正常, MCCL 互联测试通过)

# 1) 节点标签 (hostNetwork 端口冲突, 各角色节点互斥; size=4 需每角色 ≥4 台)
kubectl label node <p1> <p2> <p3> <p4> metax-sglang-pd-prefill-dsv4rc3=true --overwrite
kubectl label node <d1> <d2> <d3> <d4> metax-sglang-pd-decode-dsv4rc3=true  --overwrite
kubectl label node <r1>                  metax-sglang-pd-router-dsv4rc3=true  --overwrite

# 2) 先只建 Service, 拿 leader 稳定入口的 ClusterIP (对比网关用; 不用可跳过)
kubectl -n metax-ai-pd apply -f .../deepseek-v4-rc3-maca/lws/base/services.yaml
kubectl -n metax-ai-pd get svc prefill-dist-master decode-dist-master \
  -o custom-columns=NAME:.metadata.name,IP:.spec.clusterIP
#    → 回填 base/router.yaml 的 PD_PREFILL_ENDPOINTS(<ClusterIP>:8000) /
#      PD_DECODE_ENDPOINTS(<ClusterIP>:8200)。不用对比网关时, 把 router.yaml
#      从 base/kustomization.yaml 的 resources 里去掉即可。
#    ⛔ 这两个 ClusterIP **只给客户端(router)用**, 不要填进 PD_MASTER_IP (见 §5.1)

# 3) (推荐) 先干跑: 把两个 LWS 的 PD_DRY_RUN 置 "1", 只打印 argv 不拉引擎
# 4) 正式部署 (PD_MASTER_IP 保持空, 无需手工填任何 IP)
kubectl apply -k guides/pd-disaggregation/modelserver/gpu/sglang/metax/deepseek-v4-rc3-maca/lws/
```

回滚：`kubectl delete -k .../lws/`。改动 LWS 拓扑需整组重建
（`RecreateGroupOnPodRestart`），重建前建议等待 ≥120s 让旧连接释放。

## 7. 验收清单（含实测结果）

```bash
# 1) Pod 就绪: prefill 1 组 ×4、decode 1 组 ×4(每题 2 容器)
kubectl -n metax-ai-pd get pods -l 'llm-d.ai/guide=pd-disaggregation'
#    实测: 修 §8 之前 decode 恒为 1/2（modelserver 未就绪）；修好后 2/2

# 2) 启动摘要: 确认 rank/master/nnodes 与并行度符合预期
kubectl -n metax-ai-pd logs prefill-dsv4rc3-0 -c modelserver | head -40

# 3) P/D health (对 master pod 的节点 IP)
curl -s -o /dev/null -w "%{http_code}\n" http://<prefill-master-ip>:8000/health
curl -s -o /dev/null -w "%{http_code}\n" http://<decode-master-ip>:8200/health
#    实测: 500ms~1s 内返回 200; 若 20s 后返回 503 → 命中 §9 的卡死, 不是探针问题

# 4) PD bootstrap 8998 (不能 timeout/refused)
curl -s -o /dev/null -w "%{http_code}\n" \
  "http://<prefill-master-ip>:8998/route?prefill_dp_rank=-1&prefill_cp_rank=-1&target_tp_rank=-1&target_pp_rank=-1"

# 5) Router 连通性 (hostNetwork 全网段; 详见 TROUBLESHOOTING §10)
curl -s -o /dev/null -w "decode sidecar %{http_code}\n" http://<decode-master-ip>:8000/health
curl -s -o /dev/null -w "prefill http   %{http_code}\n" http://<prefill-master-ip>:8000/health
curl -s -o /dev/null -w "epp envoy      %{http_code}\n" http://<epp-pod-ip>:8081/health
#    实测均为 200。注意 EPP 目前**不是** hostNetwork（值为 pod IP），见 §10。

# 6) 端到端（经 EPP；不要绕过 EPP 直连 sidecar，会 400）
curl -s --max-time 120 -X POST http://<epp-pod-ip>:8081/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8","messages":[{"role":"user","content":"请只回复 OK"}],"max_tokens":16,"temperature":0}'
# 期望: choices[0].message.content == "OK"
# ⚠️ 实测: EPP 侧链路正常（"EPP received request" → 下发 endpoint），
#    但后端处理首个真实请求即卡死 → 当前会超时。踩到的是 §9, 与 router 无关。
```

日志落盘在宿主机 `/var/log/sglang-dsv4rc3/{prefill,decode}-rank{0..3}.log`，Pod 重建后仍在。

## 8. 与官方 docker 模式的对应关系

官方文档（沐曦 v0.5.12 大模型分布式部署指南）的 docker 启动方式 → K8s 等价映射：

| docker 参数 | K8s 等价 |
|-------------|----------|
| `--privileged` | `securityContext.privileged: true` |
| `--network=host` | `hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet` |
| `--ipc=host` | `hostIPC: true` |
| `--ulimit memlock=-1` | 容器内 `ulimit -l unlimited` |
| `--security-opt seccomp/apparmor=unconfined` | `privileged: true` 覆盖 |
| `-v /home/models:/home/models` | `hostPath` 卷 + `volumeMounts` |
| `bash sglang/prefill.sh <spec> <ip> <n> <rank>` | `PD_LAUNCH_MODE=official` |
| 推荐配置的显式 launch_server 命令 | `PD_LAUNCH_MODE=explicit`（默认） |

官方文档中的环境检查（`mx-smi`、MCCL 双机测试、DeepEP Low-Latency）仍应先在宿主机完成。

## 9. 与相邻方案的差异

| 项 | GLM (`metax/lws/`) | V4-Flash (`metax/deepseek-v4-flash/`) | **本方案** |
|----|--------------------|----------------------------------------|-----------|
| 镜像 | `glmpd` | `0.5.12-dsv4` | `v0.5.8-deepseek-v4-rc3-maca...` |
| LWS 拓扑 | 1×size4 / 1×size4 | 4×size1 / 4×size1 | **1×size4 / 1×size4** |
| 参数化 | 硬编码 | ConfigMap + 运行时 sed | **env 驱动的双模式启动器** |
| 启动方式 | 官方脚本 | 官方脚本 + sed | **explicit（默认）/ official 可选** |
| 节点标签 | `...-prefill/-decode` | `...-prefill-dsv4/-decode-dsv4` | `...-prefill-dsv4rc3/-decode-dsv4rc3` |
