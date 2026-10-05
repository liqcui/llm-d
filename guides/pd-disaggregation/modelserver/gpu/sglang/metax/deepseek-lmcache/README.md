# deepseek-lmcache — LMCache（MP 模式）@ 最优解拓扑 PD 分离

> 2026-10-06 建立（就绪资产型）。目标：把 **LMCache** 作为 KV 缓存层引入 DeepSeek-V4-Flash
> PD 分离集群，以"独立 daemon 池（跨引擎重建存活）"补上 HiCache L2（池在引擎进程内，
> 重建即清空）与 Mooncake L3（MACA 写回竞态被平台阻塞）都缺的那一环。

## 0. 现状摘要（TL;DR）

| 环节 | 状态 | 依据 |
|---|---|---|
| LMCache 本体 × 沐曦 GPU | ✅ 官方支持 | MXMACA 合入 LMCache 主线（PR #4606，2026-09）；`setup_extensions/build_profiles/maca.py` 一等公民 |
| 厂商 SGLang fork 的 `--enable-lmcache` 集成代码 | ✅ 完整（0.5.13/0.5.14 均有） | 镜像内 `srt/mem_cache/storage/lmcache/`（LMCRadixCache，读 `lmcache.integration.sglang.*`） |
| 镜像内 lmcache 包 | ✅ 本目录补齐（**2026-10-06 实测闭环**） | `image/`：MACA 编译 ✓ → fork 三件套 adapter 导入 ✓ → `lmcache server` daemon 实起 LISTEN ✓ → **镜像已构建并推送 harbor**（digest `46a98639…`） |
| MP daemon + 部署骨架 | ✅ 已就绪（kustomize 渲染验证 ✓） | `daemon/` DaemonSet + `base/lmcache-config.yaml` + launcher 预埋注入 |
| **引擎侧对 DSv4 启用** | ⛔ **结构性门禁未解锁** | registry 选择顺序（§3）；上游修复 PR 未进厂商镜像 |
| 解锁成本 | 一行 env | `PD_ENABLE_LMCACHE=1`（launcher 已预埋注入逻辑） |

**一句话**：一切就绪，只差厂商镜像 rebase（或上游 connector 验证落地）解锁 DSv4 的
hybrid SWA 门禁；解锁前本目录可先部署"锁定态基线"（引擎与最优解严格同构 + daemon 冒烟）。

## 1. 目标与定位

- **拓扑**：与生产最优解严格同构 —— prefill pp1/tp8/dp4、decode pp1/tp8/dp4、8 节点 64 卡。
  唯一变量 = **prefill 侧缓存层**（HiCache L2 → LMCache MP daemon）与 prefill 镜像。
- **decode 侧不变**：沿用 `0.5.12-maca.ai3.8.2.7-llm` 修复镜像（与 L2 对照实验一致，
  消除无关变量）。
- **为什么值得做**（相对现有缓存层）：
  - vs **HiCache L2**（引擎内 host 池）：LMCache daemon **独立于引擎存活** —— LWS 组重建
    （崩溃恢复必走 `RecreateGroupOnPodRestart`）后新引擎直接命中旧池；且 MP 模式统一池
    可跨 DP 副本共享（文章基准：8×DP 碎片池 → 单池，TTFT 3.98s→0.29s）。
  - vs **Mooncake L3**：绕开被 MACA 平台竞态阻塞的写回路径（LMCache 有独立传输栈与
    MACA profile；且 daemon 池在本机 host 内存，不依赖 RDMA 写回）。

## 2. 方案架构（MP 模式）

```
                 ┌─────────────────────────── 每 prefill 节点 ───────────────────────────┐
 Client → EPP ──► decode sidecar:8000 ──► prefill-lmcache-x:8000 (tp8/dp4, LWS)          │
                 │      │                        │  --enable-lmcache --lmcache-config-file
                 │      ▼                        ▼  (PD_ENABLE_LMCACHE=1 解锁后)          │
                 │  decode modelserver:8200   LMCacheMPConnector ─ ZMQ ─► lmcache server  │
                 │  (0.5.12 修复镜像, 不变)     (引擎侧, hostNetwork)      127.0.0.1:5556   │
                 └──────────────────────────────────────────────────────────│──────────-┘
                                                                            ▼
                                                     DaemonSet lmcache-server（每 prefill 节点 1 个）
                                                     host-memory 池 400GB（LRU, 对齐官方基准）
                                                     引擎组重建 → 池存活
```

组件清单：

| 组件 | 文件 | 说明 |
|---|---|---|
| Prefill LWS | `base/prefill.yaml` | 最优解拓扑；镜像 `…-lmcache`；`PD_ENABLE_LMCACHE=0`（开关） |
| Decode LWS | `base/decode.yaml` | 与最优解一致（0.5.12 镜像）；不含 lmcache |
| Router | `base/router.yaml` | 对比网关（节点标签 `-lmcache` 版） |
| lmcache 配置 | `base/lmcache-config.yaml` | ConfigMap（引擎与 daemon 共用；`mp_host/mp_port/chunk_size`） |
| launcher 注入 | `base/launcher-configmap.yaml` | `PD_ENABLE_LMCACHE=1` → 向 `prefill_model_args` 注入 `--enable-lmcache --lmcache-config-file`（**预埋，解锁即用**） |
| MP daemon | `daemon/lmcache-server-daemonset.yaml` | `lmcache server --l1-size-gb 400 --eviction-policy LRU`，hostNetwork，每 prefill 节点 1 个 |
| 镜像构建 | `image/` | 多阶段 Dockerfile（builder 编译 wheel → 运行镜像装包） |
| 环境描述 | `envs/deepseek-lmcache.json` | sglbench 环境快照（对比时入 `run_environments`） |
| 测试计划 | `TEST-PLAN.md` | 解锁后的 sglbench 测试协议 |

为什么 **MP 模式**（daemon）而非 IP（进程内）：IP 模式"池与引擎同生共死"，退化成
HiCache L2 的形态；MP 的存活性与统一池才是引入 LMCache 的全部理由。
为什么 **prefill-only**：多轮对话/前缀复用的命中发生在 prefill 侧；decode 侧 radix 缓存
是上游另一个实验特性（依赖 nixl/mooncake 传输），首版不引入。

## 3. 阻塞分析（2026-10-06 spike 证据链）

**现象**：fork 的 `--enable-lmcache` 对 DeepSeek-V4-Flash（hybrid SWA 模型）无法生效。

**根因（代码级）**：`sglang/srt/mem_cache/registry.py` 的缓存实现选择顺序为

```
… → hicache(hybrid 走 UnifiedRadixCache) → 【is_hybrid_swa → SWARadixCache/PureSWARadixCache】
  → is_hybrid_ssm → 【server_args.enable_lmcache → LMCRadixCache】 → RadixCache
```

DSv4 混合注意力（SWA + full 双池，`swa_full_tokens_ratio` 0.1/0.2/0.4 我们全跑过）
使 `is_hybrid_swa=True` → **永远先命中 SWA 分支**，`enable_lmcache` 分支静默不可达。
0.5.13（r4-hicache 系列）与 0.5.14（`0.5.14-dsv4-v2-c500`）两代镜像同样如此；
0.5.14 的 UnifiedRadixCache 组件只有 FULL/SWA/MAMBA，无 LMCache 组件。

**上游进展（解锁来源）**：
- sgl-project/sglang **#38652**「Support lmcache unified radix cache」——`--enable-unified-lmcache`
  （LMCache 挂 UnifiedRadixCache + `lmcache mp server`，fs_native L2 adapter）——**修的就是本门禁**；未进厂商镜像。
- LMCache 官方 **#4833**（MetaX MACA Backend Roadmap V2）——含 **"SGLang MACA connector
  验证报告"** 条目与 CI 接入计划；MACA 支持已随 #4606 进主线。
- LMCache 官方基准（TTFT 3.98→0.29s）用的是 Qwen3（GQA，非 SWA）——hybrid SWA + LMCache
  即使上游也属新领土，解锁后需自己出验证数据。

**已知风险（解锁前记录在案）**：
- 沐曦开发者论坛实测（vLLM 路径，C500 64G×8）：**DP=4 撞 `mxkwCreateQueueBlock timeout`**
  （驱动 hardware queue pool 上限；queue 消耗随 DP 线性增长），TP=8 DP=1 正常。
  → 我们的 prefill 恰是 dp4；LMCache 的每-rank queue 消耗是解锁验证的第一观察点。
  （缓解候选：LMCACHE 侧队列复用/降并发；或按 dp 拆 daemon 端口；属解锁调优。）
- MP daemon 在无 GPU 节点上起（cpu-only）需要 lmcache 不触碰 CUDA 初始化——**已列入
  部署检查清单**（daemon 送一个空 GPU 配额先验证；不通过则给 1 卡）。

## 4. 镜像（image/）

**配方（已实测编译通过，2026-10-06）**：

- 基座 `ARG BASE_IMAGE=…r4-hicache-l2-pp1`（含最优解拓扑补丁 + LMCRadixCache 集成代码）
- 源码编译 LMCache **0.5.5**（sdist 固定版本，`BUILD_WITH_MACA=1`）；
  MACA profile 经 `torch.utils.cpp_extension.MACA_HOME=/opt/maca` 探测，用
  `/opt/maca/tools/cu-bridge` 的 nvcc 兼容编译器直接编 `.cu`（无需 hipify），
  产出 `lmcache.cuda_ops`（与 CUDA profile 同名，MACA 报 `device_type == "cuda"` 时按此名加载）
- 多阶段构建：builder 装编译依赖（setuptools/ninja/grpcio-tools… 会与镜像内 xformers
  的 `setuptools==69.5.1` pin 冲突 → **隔离在 builder stage，不污染运行镜像**）
- 运行侧依赖：`mcpy`（cupy fork，沐曦源 `repos.metax-tech.com/r/maca-pypi`）+ `triton`
  （镜像已有 metax 版）+ lmcache 运行依赖（以冒烟为准，见 image/README.md）

构建与冒烟步骤见 **`image/README.md`**；产物 tag `…-r4-hicache-l2-pp1-lmcache`。

## 5. 部署（含检查清单）

```bash
# 0) 构建并推送镜像（image/README.md）
# 1) 节点标签（与 hicache 标签互斥; router 节点可复用）
kubectl label node mxgpu-3-28 mxgpu-3-29 mxgpu-3-31 mxgpu-3-36 metax-sglang-pd-prefill-lmcache=true --overwrite
kubectl label node mxgpu-3-32 mxgpu-3-33 mxgpu-3-34 mxgpu-3-35 metax-sglang-pd-decode-lmcache=true --overwrite
kubectl label node mxgpu-3-32 metax-sglang-pd-router-lmcache=true --overwrite
# 2) 切换部署（互斥; 先删旧）
kubectl delete -k ../deepseek-hicache-l2-pp1/ 2>/dev/null || true
kubectl apply -k .
# 3) 检查清单
kubectl -n metax-ai-pd get pods -l llm-d.ai/role=lmcache-server -o wide   # daemon 4/4 Running
kubectl -n metax-ai-pd get pods -l llm-d.ai/guide=pd-disaggregation      # 8 pod Ready
curl <prefill-leader>:8000/v1/models && curl <decode-leader>:8200/v1/models
# 4) daemon 冒烟（每 prefill 节点; 需 ssh 免密——本机 10.66.2.1 已具备）
ssh ubuntu@10.66.3.29 "sudo ss -ltnp | grep 5556"          # 端口在听
ssh ubuntu@10.66.3.29 "sudo free -g | head -2"             # 池内存实际占用（预热后）
# 5) 锁定态基线压测（sglbench; label lmcoff-opt*）→ TEST-PLAN.md
```

部署检查清单（坑位预登记）：
1. **端口 5556 冲突**：如节点既有服务占用 → 改 `daemon` env `LMCACHE_MP_PORT` 与
   `base/lmcache-config.yaml` 的 `mp_port`（两处必须一致）。
2. **daemon 无 GPU 启动**：观察 daemon 日志有无 CUDA/cupy 初始化报错；报错则给 daemon
   加 `metax-tech.com/gpu: 1` 配额。
3. **hostNetwork 回环**：引擎与 daemon 均 hostNetwork，`127.0.0.1:5556` 直连；
   若未来改 sidecar 方案需换 pod IP。
4. **日志**：引擎 `/var/log/sglang-lmcache/`（hostPath，跨重建保留）。
5. **daemon 内存**：400GB 池 + 引擎（1000Gi limit）共存于 2TB 节点；如加 `local_disk`
   缓存另计 SSD 空间。

## 6. 解锁路线图（按优先级）

| 路线 | 动作 | 成本 | 备注 |
|---|---|---|---|
| **A. 厂商镜像 rebase（首选）** | 拿到含上游 **#38652**（unified-lmcache）的 r5 镜像 → 重跑 `image/build.sh`（`BASE_IMAGE=` 参数）→ 置 `PD_ENABLE_LMCACHE=1` | 一行 env + 重建 | 与现架构同源，风险最低 |
| **B. LMCache 官方 connector 验证落地** | 跟进 LMCache #4833 的 "SGLang MACA connector" 验证报告 → 按官方文档适配 | 中（可能需换接入形态） | 官方 CI 背书，长期方向 |
| **C. fork 补丁原型（不推荐）** | 改 registry 顺序 + LMCRadixCache 直连 SWA 模型 | 高（SWA 双池 tombstone 语义 vs LMCache chunk 语义冲突） | 仅作为报证/摸底，不在本目录承诺 |

解锁验证顺序（**先验证再谈收益**）：
1. 引擎日志出现 `--enable-lmcache` 且不再静默 → `server_args` 核对；
2. daemon 侧观测到 `lookup/retrieve` 流量（ZMQ 日志）；
3. **驱动 queue pool 风险观察**（论坛 DP=4 案例）：boot 是否卡 `mxkwCreateQueueBlock`；
4. 单场景冒烟（`mini-l2-64c`）→ 与 `l2off-opt` 同拓扑对照；
5. 循环：**引擎组重建存活**测试（`kubectl delete pod` 触发 LWS 重建 → 重建后同前缀请求
   是否直接命中 daemon 池）——这是 LMCache 相对 HiCache 的**核心卖点验证**。

## 7. 测试协议

见 **`TEST-PLAN.md`**（sglbench 驱动；label 约定 `lmcoff-opt*` 锁定态 / `lmcon-opt*` 解锁态；
对照基线 = `l2off-opt*`（同拓扑非 HiCache）+ `l2pp1-opt*`（同拓扑 L2），三者严格同拓扑）。

## 8. 参考

- LMCache #4606（MACA 合入主线）/ #4833（MACA Roadmap V2）/ sgl-project/sglang #38652（unified lmcache）
- 镜像内集成说明：`/opt/conda/lib/python3.12/site-packages/sglang/srt/mem_cache/storage/lmcache/README.md`（MP/IP 模式）
- 同族部署：`../deepseek-hicache-l2-pp1/`（L2 对照）、`../deepseek-hicache-l3*/`（Mooncake L3，MACA 写回竞态被阻塞）
- 沐曦开发者论坛：vLLM+LMCache `mxkwCreateQueueBlock` 案例（DP=4 queue pool 上限）
