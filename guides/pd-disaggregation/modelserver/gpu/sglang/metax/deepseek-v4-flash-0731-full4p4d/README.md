# deepseek-v4-flash-0731-full4p4d — "真正的 4P+4D 全量"对照变体

**目的**：与 pernode 做**同硬件总量（64 卡）**的公平对照——修复老家族"每节点仅 2 卡入池"
的布局工件（全集群 16/64 卡，见 `../deepseek-v4-flash-0731-pernode/ARCHITECTURE.md` §2.2 证据）。

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
| `PD_MAX_RUNNING_REQUESTS` | 64 | 单大引擎总槽 |
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
2. decode 日志出现 `Cuda graph decode max bs is adjusted to 64`；若现
   `TypeError NoneType`（bs=tier 不在 builder 表）→ 按备选组合表降档重试：
   | 备选 | cap | graph-bs | adjusted |
   |---|---|---|---|
   | A（首选） | 64 | 80 | 64 |
   | B | 40 | 80 | 40 |
   | C | 16 | 32 | 16 |
3. E2E 单请求 200 + 单流速率粗测（非正式压测）。

## 对照测试计划（待用户批准后执行）
与 pernode **同场景同负荷**全套：single5/longctx5 + mini-32/64/128c + conc-32/64/128/160 +
rate 阶梯 + DSPARK (已在两侧开启)。产出：`dsv4-0731-f4-*` labels → DuckDB → 对比报告。

> 家族文档：`../deepseek-v4-flash-0731-pernode/{ARCHITECTURE,OPTIMIZATION,DEPLOY}.md`
