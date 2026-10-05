# deepseek-lmcache 测试计划（sglbench 驱动）

> 对齐 skill `sglbench-hicache-testing` 的规范：同拓扑对照 / env-file 入库 / label 约定 /
> 数据不手搓。执行前提：解锁完成（`PD_ENABLE_LMCACHE=1` 且引擎日志确认生效）。

## 0. 部署态与 label

| 阶段 | 部署 | sglbench label | 说明 |
|---|---|---|---|
| 锁定态基线（daemon 就绪未接线） | 本目录（`PD_ENABLE_LMCACHE=0`） | `lmcoff-opt*` | 与最优解同构；daemon 同跑但不被引擎使用 |
| 解锁态 | 本目录（`PD_ENABLE_LMCACHE=1`） | `lmcon-opt*` | 引擎侧 LMCache 生效 |

对照（两侧均已在库，无需重跑）：

| 对照 | label | 拓扑 | 角色 |
|---|---|---|---|
| 非 HiCache 最优解 | `l2off-opt*` | pp1/tp8/dp4 | **主对照**（与 lmcoff/lmcon 严格同拓扑） |
| HiCache L2 | `l2pp1-opt*` | pp1/tp8/dp4 | 次对照（缓存层横向：L2 vs LMCache） |

## 1. 环境文件

每次 run 必须带 `--env-file envs/deepseek-lmcache.json`（本目录提供；解锁后把
`notes` 更新为"已解锁"并复核 `engine_version`）。

## 2. 场景矩阵（scenario key 稳定，勿改参数）

| 类别 | key | 目的 |
|---|---|---|
| 稳定边界 | `mini-l2-32c` / `mini-l2-64c` / `mini-l2-128c` | 低/中/高并发下的收益与稳定性 |
| 多轮（核心价值场景） | `hicache-multiturn-20x10` / `hicache-multiturn-80x10` | 逐轮 TTFT 断崖（round1 冷热转换） |
| 官方案例 | `hicache-multiturn-80x10-r16 --max-parallel 4` | 对齐官方 H800 协议 |
| 极限 | `conc-256-deepseek`（rate 16） | 高并发 + daemon 池压力 |

## 3. 执行命令（标准流程）

```bash
cd ~/sglang-benchmark-tools

# ① 前置检查
python3 -m sglbench status
curl <prefill-leader>:8000/v1/models          # 200 才算 leader（漂移需同步 router）

# ② 锁定态基线（部署锁定态时跑）
python3 -m sglbench run --scenario mini-l2-64c --exec docker --label lmcoff-opt \
  --env-file ../llm-d/guides/pd-disaggregation/modelserver/gpu/sglang/metax/deepseek-lmcache/envs/deepseek-lmcache.json \
  --auto-retry 3 --fail-on-bad
python3 -m sglbench multiturn --scenario hicache-multiturn-20x10 --label lmcoff-opt-mt20 \
  --env-file .../envs/deepseek-lmcache.json

# ③ 解锁后同套场景重跑（label lmcon-opt*）
# ④ 对比与报告（三方能对比）
python3 -m sglbench compare <l2off-run> <lmcon-run> --baseline <l2off-run>
python3 -m sglbench campaign report --pair 'l2off-opt*=lmcon-opt*' -o reports/lmcon-vs-l2off/
python3 -m sglbench campaign report --pair 'l2pp1-opt*=lmcon-opt*' -o reports/lmcon-vs-l2pp1/
```

## 4. 核心验证点（解锁后按序）

1. **负基线一致性**：`lmcoff-opt` ≈ `l2off-opt`（引擎未接线时收益应≈0，用于证明
   部署切换无拓扑/参数漂移）。
2. **逐轮断崖**：`lmcon-opt` 的 round1 vs round0 断崖深度 ≥ `l2pp1-opt`（daemon 池
   更早命中）？round1 Δ 是本项目第一指标。
3. **引擎重启存活（核弹级验证）**：
   - `python3 -m sglbench status` 记录基线 → `kubectl delete pod prefill-lmcache-0-0`
     触发 LWS 组重建 → 等健康（~5-8 min）；
   - 立刻重跑同一 `hicache-multiturn-20x10`（label `lmcon-opt-resume`）；
   - **预期**：round0 冷启动 TTFT 显著低于全新引擎（daemon 池未随引擎丢）——这是
     HiCache/L2 做不到而 LMCache 独有的能力，收益若成立即为生产切换的最强理由。
4. **queue pool 观察**：解锁后 boot 阶段 grep 节点日志
   `mxkwCreateQueueBlock`（论坛 DP=4 案例信号）；与引擎启动日志一并归档。
5. **稳定性**：mini-128c 与 conc-256 两档复跑 ≥2 次；任何 xnack/mv0x4 崩溃 →
   `sglbench forensics <run_id>` 归档（自动触发已有，手动补采兜底）。

## 5. 判定与产出

- 判定阈值沿用 sglbench：噪声 ±5%（`compare` 默认）；逐轮断崖 ±10%（rounds 模块）。
- 产出：`campaign report` 全套（index.html + SUMMARY.md + 每场景明细）×2 组对照；
  结论表与建议并入 `TEST-REPORT-<date>-lmcache.md`（docs/）。
- 结论模板：
  - LMCache vs 非 HiCache：TTFT/TPOT/吞吐 Δ + round1 Δ + 重启存活 Δ；
  - LMCache vs HiCache L2：在"重启存活 / 引擎无关"两维上的增量价值是否值得多一个 daemon。
