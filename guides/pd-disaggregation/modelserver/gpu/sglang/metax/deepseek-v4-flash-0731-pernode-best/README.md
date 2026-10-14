# deepseek-v4-flash-0731-pernode-best — ★ pernode 最优解（终版冻结，2026-10-14）

> 本目录 = **0731 体系统合最优解的快照**（拓扑 + 全量 sglang 参数 + router 策略 + 证据索引）。
> 来源：10-12 终版标定 + 10-14 收官日（三形态终版数据集 / 修复战役 / router 策略 A/B / 边界阶梯）。
> **原始目录（pernode/）原样保留**；本目录为冻结的最优配置面（两者当前一致，后续演进只动本目录）。

## 1. 最优解定义（一句话）

**4+4 台单节点自包含 tp8 引擎（每引擎独占节点 8 卡；引擎内无 DP/PP；DP 与配对在 router 层逐请求完成）
+ 每引擎 decode max-running 48 / graph-bs 64（>48 规则）+ DSPARK block6 + router 默认双 cache_aware。**

## 2. 拓扑

| 侧 | 形态 | 说明 |
|---|---|---|
| prefill ×4 | 每节点 1 台 tp8/dp1/pp1 引擎（node 29/31/36/28） | explicit 直启（LWS replicas=4/size=1） |
| decode ×4 | 每节点 1 台 tp8/dp1/pp1 + DSPARK block6（node 35/34/33/32） | prefill max-running 64 / decode max-running **48** /引擎 |
| router | 4+4 端点列表，逐请求 PD 配对；hostNetwork :8001（node 32） | **策略=默认（prefill 与 decode 皆 cache_aware）——F1 实测胜出，见 §4** |
| KV 传输 | 各引擎自足（mooncake，ib 单轨） | 无需跨引擎协调 |

## 3. 冻结参数（= pernode `lws/base/*.yaml` 当前值，均为实测标定）

| 参数 | 值 | 依据 |
|---|---|---|
| 引擎/节点 | prefill 4 + decode 4（每台独占 8 卡，全集群 **64/64 卡**） | 单机探测 2.2x 收益；足迹核验 §5 |
| decode `PD_MAX_RUNNING_REQUESTS` | **48**/引擎（×4=192 总量） | cap 阶梯 16（队列崩）/32（无余量）/**48（全包络最优）** |
| decode `PD_CUDA_GRAPH_MAX_BS` | **64**（>48 → adjusted 48 触发重建） | DSPARK bs=None 缺陷规避（dp1 下 min≡request 永不重建 → 必须 >max-running） |
| prefill `PD_MAX_RUNNING_REQUESTS` | 64/引擎 | 与 decode 同步标定 |
| DSPARK | on / block 6 / ep1 | 单流 TPOT 5.5 vs 16.6ms（3x）、吞吐 2.5x（A/B 实锤必留） |
| mem-frac | prefill 0.82 / decode 0.75 | rc3 标定；**10-14 未做 0.78 A/B（时间限制）— 未来可试**（pp4full/pp1 上 0.78 解了两类崩溃） |
| L2（HiCache） | off（`PD_ENABLE_HICACHE=0`） | L2 A/B 双绿；多轮共享前缀场景可开（见 pernode 目录 FINAL 数据 label `final-2026-10-14-pernode-l2`） |
| 镜像 | `0.5.14-maca.ai3.8.2.122-dsv4-0731-llm-retractfix`（46db2551） | retractfix 内置 |
| 其余 | chunked 16384 / page 64 / swa 0.1 / context 400K / kv bf16 / env 对齐（TP_MEMORY 检查=0） | 各形态统一 |

## 4. Router 策略结论（F1 实测，10-14 晚）

**默认策略（不做任何 `--policy` 设定）胜出**——cache_aware 自带 abs±64/rel 1.5× 负载均衡阈值，
天然是"前缀亲和 + 负载均衡"混合体：

| 格（同集群对照） | 默认（双 cache_aware） | prefill=cache_aware + decode=**power_of_two** |
|---|---|---|
| steady r2 | **TTFT 964ms / TPOT 9.1ms** | 2000ms / 11.1ms |
| std-c128 | **1244ms / 12.3ms** | 1300ms / 19.3ms |
| std-c160 | **1520ms / 17.4ms** | 1848ms / 16.5ms |

→ **3/3 格默认胜**；`--prefill-policy / --decode-policy` 高级旗标在 sglang-router 0.3.2 可用，
但本场景无收益（数据 label `routerpol-p2-*`）。共享前缀生产负载下 cache_aware 价值只增不减。

## 5. 战绩与安全边界（10-14 终版数据）

- **全场景**：42/42 ok（`final-2026-10-14-pernode`，3h10m，零整组崩溃）
- **安全边界**：**conc ≤ 160 @ rate ≤ 5 = 零崩溃包络**（峰值 **3354 tok/s**、conc160 TTFT **2.0s**、
  单流 TPOT 5.5ms、rate2 容量点 2903 tok/s）；**conc ≥ 176 = 服务层崩解**（router 熔断型，引擎不崩）；
  **rate ≥ 8 = 引擎级崩溃**（跨引擎级联）
- **平台故障特性**：B 类设备故障（.32 等）在此形态下=**单引擎隔离**（1/8 算力闪断，全站不崩，
  router 自动剔除）——对比 pp4full 的全站级联
- **足迹**：全集群 64/64 卡（每节点 8 进程 × ~50GB，`run_full8_comparison.sh footprint pernode` 核验）

## 6. 部署 / 运维

```bash
# 部署（渲染→apply；首次切换或拓扑变更后需清旧 pod 防 LWS 滚动死锁）
cd .../metax && python3 tools/render_site.py deepseek-v4-flash-0731-pernode-best
kubectl apply -k deepseek-v4-flash-0731-pernode-best/_rendered/lws/
# ⚠ 拓扑切换（replicas/size 变更）后：核对 LWS generation + 清旧组 pod；boot ~6-15min
# 就绪核验：8 pod（prefill 1/1×4, decode 2/2×4）；真实 /generate 探测（勿只信 /health）
# router：4+4 端点列表（对齐各引擎节点 IP）；deploy env 任何改动后 scale 0→1 重启 router pod
```

## 7. 证据索引（全部在 sglbench 仓 + MinIO 备份）

- 报告：`TEST-REPORT-2026-10-13-safe-boundary-0731.md`（终版）+ `PARAMS-SUMMARY-2026-10-14.md`
- 崩溃学：`TROUBLESHOOTING-2026-10-14-dsv4-0731-pp4full-crashes.md`（四类框架）
- 数据：label `final-2026-10-14-pernode`（42 run）/ `boundary-probe-pernode-*`（4 格）/
  `routerpol-p2-*`（3 格）/ `final-2026-10-14-pernode-l2`（L2 A/B）
- 备份：`minio/cubestack-full-offline-files/sglbench-backup-20261014/`
