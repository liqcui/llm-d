# deepseek-v4-flash-0731-full4p4d — "真正的 4P+4D 全量"对照变体

**目的**：与 pernode 做**同硬件总量（64 卡）**的公平对照——修复老家族"每节点仅 2 卡入池"
的布局工件（全集群 16/64 卡，见 `../deepseek-v4-flash-0731-pernode/ARCHITECTURE.md` §2.2 证据）。

> **等价关系（重要）**：本形态 = **"pp1-explicit 形态的全量修正版"**——同一 explicit 启动链路、
> 同一引擎（单大引擎/引擎内并行），仅 `tp 8→32` 使 8 卡/节点全入池（机理：引擎按
> `每节点卡数 = 总 rank/nnodes` 派生本地 worker：tp8/4 节点→2 卡；tp32/4 节点→8 卡）。
> 重测名单中"pp1-explicit（全量）"即指本目录。

> ⛔ **2026-10-13 首启实测定论：本形态原理不可行（已终止推进）**——tp32 撞模型硬约束：
> DSv4 attention 仅 **8 个 output groups**，tp=32 时 `n_local_groups = 8/32 = 0` → decode
> CUDA graph 捕获期崩溃 `RuntimeError: shape '[336, 0, -1]' is invalid for input of size 344064`
> （`deepseek_v4.py:1190` `o.view(o.shape[0], self.n_local_groups, -1)`），decode 组进入 LWS
> 整组重建循环（每代 ~2-6min），prefill 同因不可用。崩溃证据：node35
> `/var/log/sglang-dsv4-0731/decode-rank0.log`（graph 捕获期，TP4 rank 先崩→gloo 级联）。
> **正确约束 = `o_groups % tp == 0` → tp ≤ 8**（本 README 原 "32 % o_groups(8)=0 ✓" 检查方向写反）。
> **推论（修正 ARCHITECTURE §2.2 末句）**：本模型**无法构造"跨节点单引擎 × 8 卡/节点"**
> ——"引擎内 DP vs router 层 DP 的同硬件公平对照"不存在；8 卡/节点唯一表达 = pernode。
> 对照实验意义转移至 §5.9 资源对齐实验（单引擎 8 卡节点内 vs 2 卡跨节点，隔离互联因素）。
> （graph-tier 备选组合 A/B/C 与 NoneType 预案均与本崩溃无关——首启实际触发 adjusted=48 重建成功，
> 崩溃在模型 forward 形状层，与 bs 无关。）

## 对照设计（两形态均 8 卡/节点全量）
| | pernode（现状最优） | **full4p4d（本目录, 待验证）** |
|---|---|---|
| prefill 形态 | 4 台独立引擎（每节点 1 台 tp8） | **1 台大引擎（tp32 跨 4 节点, 8 卡/节点全入池）** |
| decode 形态 | 4 台独立引擎 + DSPARK | **1 台大引擎（tp32）+ DSPARK** |
| DP 位置 | router 层（4+4 配对） | 引擎内（dp1, tp 承担全部并行） |
| 调度 | 4 个独立调度器 | 单调度器全局队列 |
| 每层通信 | **节点内** A2A | **跨节点** A2A（8 卡/节点，流量比老形态 4x） |
| 硬件利用 | 64/64 卡 | 64/64 卡 |

## 参数（终版级配置，待首启验证后微调）
| 参数 | 值 | 说明 |
|---|---|---|
| `PD_TP_SIZE` | **32** | 8 卡/节点 × 4 节点全量；32 % o_groups(8)=0 ✓ |
| `PD_DP_SIZE` | 1 | 引擎内不切 DP（与 pernode 的 router-DP 形成对照） |
| `PD_MAX_RUNNING_REQUESTS` | **48** | 对齐最优解值（单引擎语义=全体槽位；pernode 为 4×48=192） |
| `PD_CUDA_GRAPH_MAX_BS` | **80** | ⚠ 必须 > max-running（bs 重建缺陷规避，OPTIMIZATION §5.1） |
| DSPARK | on (block6) | 与 pernode 对齐 |
| 其余 | 同基线 | retractfix 镜像 / 16K chunked / mem 0.82,0.75 / L2 off |

## ⓪ 部署（IP 脱敏链路同族）
```bash
cp site-config.env.example site-config.env     # 填真实 IP（仅用 IP_PREFILL_0 / IP_DECODE_0）
python3 ../tools/render_site.py .
kubectl apply -k _rendered/lws/
```
与 pernode/pp1/pp4 同名资源互斥；切换后按 `DEPLOY.md §5.2` 同步 router 端点。

## ⚠ 首启验证清单（未压测前必做）
1. 8 进程/节点（每卡一个 scheduler）→ `sudo mx-nvidia/mx-smi` 进程表 8 行；
2. decode 日志出现 `Cuda graph decode max bs is adjusted to 48`（yaml 现值 cap48/graph80；
   adjusted=min(80,48)=48≠80 触发 bs 重建；48 为 pernode 已验证档）；若现
   `TypeError NoneType`（bs=tier 不在 builder 表）→ 按备选组合表降档重试：
   | 备选 | cap | graph-bs | adjusted |
   |---|---|---|---|
   | A（当前 yaml） | 48 | 80 | 48 |
   | B | 40 | 80 | 40 |
   | C | 16 | 32 | 16 |
3. E2E 单请求 200 + 单流速率粗测（非正式压测）。

## 重测名单（用户要求：全部形态均"全量 8 卡/节点"）
| 形态 | 8 卡/节点表达 | 状态 |
|---|---|---|
| pernode（router 层 DP, 4×8 卡引擎） | 天然全量（每引擎=单节点 8 卡） | ✅ 已跑全量数据 |
| **full4p4d（= pp1-explicit 全量版）** | tp32 = nnodes×8 | 脚本就绪，待首启验证 |
| pp4-official（全量版） | pp4×tp8=32 卡（8/节点）——⚠ 其"2 卡"为**推断未实测** | 启动后按 mx-smi 实测足迹；若不符需查 vendor 布局 |
| （对照）pp1 目录保留 tp8 旧形态 = 2 卡/节点的历史态 | — | 归档（资源对齐实验 §5.10 用） |

## 对照测试计划（待用户批准后执行）
与 pernode **同场景同负荷**全套：single5/longctx5 + mini-32/64/128c + conc-32/64/128/160 +
rate 阶梯 + DSPARK (已在两侧开启)。产出：`dsv4-0731-f4-*` labels → DuckDB → 对比报告。

> 家族文档：`../deepseek-v4-flash-0731-pernode/{ARCHITECTURE,OPTIMIZATION,DEPLOY}.md`
