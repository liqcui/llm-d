# OPTIMIZATION — 0731 PD 分离最优参数解（终版定版，2026-10-12）

> **0.5.14 + DSPARK，PD 分离最佳性能的完整参数解。**
> 本文件为**交付定版**：所有取值均有实测依据（DuckDB 全量入库，证据索引见 §6）。
> 本目录（pernode）即为该最优解的**参考实现**；历史形态（pp1/pp4/单机）作为对照
> 保留在相邻目录。

---

## §0 架构结论：为什么是 pernode

**对比矩阵**（同引擎 0.5.14 + DSPARK，全战役数据）：

| 架构 | 单流 | 并发吞吐 | 稳定性 | 判定 |
|---|---|---|---|---|
| **pernode（4+4 每节点独立 tp8 引擎）** | **TPOT 5.5ms** | **峰值 3354 tok/s** | 优（全战役偶发自愈） | 🏆 **最优** |
| 跨节点单引擎（tp8 跨 4 节点 / dp4，pp1） | TPOT 9.3ms | 2179 | 优 | 备选基线 |
| pp4-official（厂商脚本） | TPOT 9.3ms | 1714-2217 | **差（崩溃 6-10x）** | 仅 65K 长单流特解 |
| 单机（非 PD） | 224 tok/s 单流 | 2592@128c | — | 非 PD 参照 |

**pernode 的本质**：仍是严格 PD 分离（角色分离 + mooncake KV 传输）；
差异在单引擎的并行边界 = **节点内 tp8（8 卡高速互联）**，DP 扩展由 router 承担（4+4 逐请求配对）。
收益主因：每层 A2A 从跨节点网络回到节点内 → 每步解码 ~1.7x。

---

## §1 参数总表（最优解定版）

### 1.1 架构与部署
| 参数 | 值 | 位置 | 依据 |
|---|---|---|---|
| 启动模式 | **explicit 直启**（pd-launcher） | launcher-configmap | 官方脚本路径有 ~4s 单流税 + 崩溃 7x（§4） |
| prefill 组 | **4 组 × 1 节点**，每台 tp8/dp1/pp1 | prefill.yaml (replicas=4, size=1) | §0 |
| decode 组 | **4 组 × 1 节点**，每台 tp8/dp1/pp1 + DSPARK | decode.yaml | §0 |
| router | 端点列表 4+4（hostNetwork），逐请求 prefill↔decode 配对 | router.yaml | 分配均衡实测 ✓（4 引擎负载差 <15%） |
| 镜像 | `0.5.14-maca.ai3.8.2.122-dsv4-0731-retractfix`（fb9cff47） | 两 yaml | retract 崩溃修复闭环（§5） |
| 模型 | `DeepSeek-V4-Flash-0731-W8A8`（LLMC SmoothQuant） | PD_MODEL_PATH | — |

### 1.2 核心引擎参数（每引擎）
| 参数 | 值 | 说明 |
|---|---|---|
| `max-running-requests` | **48** | 命中全包络（×4=192）；16→并发 TTFT 崩、32→160 无余量（§3 cap 阶梯） |
| `cuda-graph-max-bs` | **64** | ⚠ 必须 **> max-running**（引擎 bs 重建缺陷规避，§5） |
| `speculative-algorithm` | **DSPARK**（`PD_ENABLE_DSPARK=1`） | block 6；A/B 实测 3x TPOT / 2.5x 吞吐（§3） |
| `speculative-dspark-block-size` | 6 | accept 0.78-0.83 近饱和 |
| `context-length` | 400000 | 业务值 |
| `chunked-prefill-size` | 16384 | 引擎归一（dp-attn 形态下自动 4096，dp1 保持 16384） |
| `mem-fraction-static` | prefill 0.82 / decode 0.75 | 既有标定（0.5.14 重标 0.78 未做，低优） |
| `kv-cache-dtype` | bfloat16 | — |
| `page-size` | 64（引擎归一 256） | 引擎行为 |
| `schedule-conservativeness` | 0.6（引擎硬改 0.18） | 不可调（引擎锁定） |
| `swa-full-tokens-ratio` | 0.1 | rc3 标定（消除 retract） |
| `disaggregation-ib-device` | mlx5_0 | 单轨（双轨 A/B 未跑，低优） |
| `ep-size` | **1** | decode ep>1 时 DSPARK verify graph 必崩 |
| L2（HiCache） | **off** | 随机负载无效应；多轮场景按需开（单 env 切换） |
| DSPARK 必配 env | `SGLANG_DSPARK_KERNEL_COMMIT_KV_PROJ=torch` 等 5 项 | 用户验证配置 |

### 1.3 禁用清单（实测踩坑）
| 配置 | 后果 |
|---|---|
| `max-running=160` | 引擎 boot 必崩（bs NoneType，§5） |
| `max-running=64`（dp1 形态 + graph-bs≤64） | 同根因 boot 崩——dp1 下必须 graph-bs>cap |
| decode `ep-size>1` | DSPARK draft verify graph 捕获必崩 |
| 官方脚本模式 + 高并发 | 崩溃率 6-10x（模式放大因子） |
| conc >160（本代未测）；rate ≥8 | 未验证区 |

---

## §2 分场景最优操作点（pernode 终版实测）

| 场景 | 推荐参数 | TTFT | TPOT | 吞吐 |
|---|---|---|---|---|
| **日常稳态（默认）** | rate 2（≤64 并发） | **1.05s** | 14.8ms | **2903 tok/s** |
| 高峰（160 并发） | rate 5 | **2.00s**（零失败） | 18.9ms | **3354 tok/s**（峰值） |
| 短并发爆发（≤128） | — | 1.48s | 18.2ms | 3199 |
| 单流 4K | — | ~0.8s | **5.5ms** | 137 |
| 单流 65K | ⚠ 建议切 pp4-official（5.3s）或接受 13.0s | 13.0s | 5.5ms | 141 |

---

## §3 关键决策实验（数据索引）
| 实验 | labels | 结论 |
|---|---|---|
| DSPARK on/off | `dsv4-0731-pernode-nospark-*` vs 基线 | 3x TPOT → 必开 |
| cap 阶梯 16/32/48 | `dsv4-0731-pernode{,-c32,-c48}-*` | 48 全包络最优 |
| 全场景电池 | `dsv4-0731-pernode-*`（21 格） | §2 表 |
| 老 PD/pp4/对齐/单机对照 | `dsv4-0731-{final-pp1,pp4off,al1,al4,sm-*}` | §0 矩阵 |

## §4 模式效应（为何不用官方脚本模式）
- 单流 4K TTFT +3.8s（0.65→4.5s，两侧官方均慢）；崩溃率放大 ~7x。机制未定位（后续项）。

## §5 已知引擎缺陷（规避已内置）
1. **cuda-graph bs NoneType**：`--cuda-graph-max-bs` 给定即清空 bs 列表、仅当
   `min(req,mr)≠req` 时重建 → dp1 或 cap≥req 组合必崩（cap160 同根因）。
   **规避：graph-bs > max-running**（本目录 64>48）。建议上游修复（bs=None 时重建）。
2. retract→SWA offload 崩溃（**已修复**，retractfix 镜像）。
3. func_timer DuplicateTimeseries（**已修复**，同镜像）。
4. KV-full 断言（老 PD cap64 重载偶发；pernode 全战役未复现）。

## §6 证据与文档索引
- 综合对比：`sglang-benchmark-tools/docs/TEST-REPORT-2026-10-10-0731-comprehensive.md` §9
- 包络报告：`…/TEST-REPORT-2026-10-12-stable-envelope-0731.md`（修订指针）
- 全部 run：DuckDB `data/bench.duckdb`（labels 见 §3）
- 提交：llm-d `3990ef4e` ｜ sglbench `0608066`
