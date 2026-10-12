# ARCHITECTURE — 0731 PD 分离架构白皮书（全拓扑）

> 本文档 = 0731 DeepSeek-V4-Flash PD 部署的**架构参考**：四种拓扑的架构/流程/参数详解/设计决策依据。
> 运维手册见 `DEPLOY.md`；参数最优解定版见 `OPTIMIZATION.md`；性能数据索引见其 §7。

---

## 1. 全局视角

### 1.1 硬件底座
- 8 节点 × 8×MetaX C500（每节点 64GB×8），节点内高速互联（dies）、节点间 200G RoCE（`mlx5_0`）
- Kubernetes + LWS（LeaderWorkerSet）+ **hostNetwork 部署模型**（引擎直接绑宿主机 IP/端口）
- 模型 `/data/DeepSeek-V4-Flash-0731-W8A8`（LLMC SmoothQuant W8A8，~287GB）

### 1.2 为什么做 PD 分离
prefill（并行计算密集、吃算力）与 decode（串行逐 token、吃访存与 KV 带宽）的**资源特性相反**：
- 分离后各自独立扩缩、独立调参（chunk/cap/graph 互不牵制）
- KV 经 RDMA（mooncake）从 prefill 机器直达 decode 机器，decode 不再重复 prefill 计算
- 代价：一次网络跳（KV 传输）+ 路由配对复杂度 → 本白皮书的目标就是把这个代价压到最低

### 1.3 软件栈分层
```
┌─ client ──────────────────────────────────────────────┐
│  (压测器 / 业务)  →  http://<router>:8001               │
└──────────────┬────────────────────────────────────────┘
┌─ router 层 ──┴────────────────────────────────────────┐
│  smg PD 路由器 (Rust): 端点池 4+4 · 逐请求配对 ·         │
│  bootstrap_room · 健康检查 · 熔断 · 重试                 │
└──────┬────────────────────────────┬───────────────────┘
┌─ prefill 引擎群 ─┴─┐   ┌─ decode 引擎群 ─┴─────────────┐
│ 4× 独立 tp8 引擎    │   │ 4× 独立 tp8 引擎 + DSPARK      │
│ (节点内 8 卡)       │⇄KV⇄│ (节点内 8 卡)                │
└────────────────────┘   └───────────────────────────────┘
        mooncake (RDMA mlx5_0) · bootstrap :8998 握手
┌─ 引擎/镜像层 ─────────────────────────────────────────┐
│ sglang 0.5.14 (+retractfix) · DSPARK 投机解码            │
└───────────────────────────────────────────────────────┘
```

---

## 2. 四种拓扑形态

### 2.1 pernode —— 每节点独立引擎（🏆 当前最优）
```
node29: [prefill 引擎 tp8 节点内 8卡] ─┐
node31: [prefill 引擎 tp8]            ├─ router 端点池 (prefill×4)
node36: [prefill 引擎 tp8]            │
node28: [prefill 引擎 tp8]            ┘
                                      ├─ 逐请求配对 (Pi, Dj)
node35: [decode 引擎 tp8 + DSPARK] ─┐ │   bootstrap_room 握手
node34: [decode 引擎 tp8 + DSPARK]  ├─┘   KV: Pi →(mooncake)→ Dj
node33: [decode 引擎 tp8 + DSPARK]  │
node32: [decode 引擎 tp8 + DSPARK] ─┘
```
- **并行语义**：每台引擎 tp8/pp1/dp1/ep1（张量并行**在节点内** 8 卡高速互联）；**DP=4+4 在 router 层**
- 为何快：每层 A2A 不出节点 → 单流 ITL 5.5ms（跨节点形态 9.3ms）；引擎间零耦合
- 代价：8 台引擎运维面；65K 长 prefill 无 PP 流水线（见 2.3）

### 2.2 跨节点单引擎（旧基线 pp1/explicit）
```
node28+29+31+36 ── 1 台 prefill 引擎: tp8 跨 4 节点 (每节点 2 卡) + dp4 + dp-attention
node32+33+34+35 ── 1 台 decode  引擎: tp8 跨 4 节点 + dp4 + DSPARK
```
- **并行语义**：tp8 的 8 个分片分布到 4 节点（2 卡/节点）→ **每层 A2A 走跨节点网络**
- 结果：单流 ITL 9.3ms、峰值 2179 tok/s
- 优点：单一大引擎、调度器内部全局队列（特定场景排队行为更平滑）

> ⚠ **"每节点仅 2 卡入池"的事实与性质（2026-10-13 深挖，本形态与 pp4-official 同）**：
> - **进程级证据**：每节点仅 **2 个** `sglang::schedul`（各 ~50.7GB），其余 **6 卡仅 866MB 空转**
>   → **全集群 16/64 卡在用（25%）**；对照 pernode 为 8 进程/节点、8/8 卡入池。
> - **成因 = 历史性布局工件**：多节点 runner 按 `每节点入池卡数 = tp/nnodes（8/4=2）` 派生分片位置；
>   厂商脚本同族公式（`tp=nnodes×num_dies/pp` + `o_groups` 整除守卫）把 tp 锁在 8，两代旧形态均继承。
>   **非有意设计**；老形态间的所有对比均为共模，曾长期掩盖该浪费（直到单机探测暴露）。
> - **对比口径警示（重要）**：老形态（16 卡在用）vs pernode（64 卡在用）的吞吐对照
>   **混杂了「硬件利用率 ×4」与「节点内 vs 跨节点互联」两个因素**——
>   ① **选择口径**（实际部署哪一个）：两者可比，pernode 胜（老设计主动闲置 75% 硬件 = 其设计缺陷）；
>   ② **机制口径**（节点内互联值多少）：**不公平/未解耦**——需资源对齐实验（每侧各 1 台 8 卡引擎，
>   见 §5.9）。按"每引擎 8 卡"同资源看，老形态单引擎的 per-card 成绩并不差（其瓶颈压在
>   fabric+并发侧），pernode 的工程价值在于把两者一起消掉。

### 2.3 pp4-official（厂商脚本，长 prefill 特解）
```
prefill: 1 台引擎 tp8/pp4/dp1 —— 4 节点各承载 1 个流水级 (11,11,11,10 层分区)
decode : tp8 跨 4 节点 + dp4 + DSPARK（与 2.2 同构）
```
- **为何长上下文快**：65K prompt 被切成 4 级流水并行 prefill → TTFT 5.3s（pernode 13.0s）
- 缺点：官方脚本路径税（4K 单流 +3.8s）+ 崩溃率 6-10x → 仅作长单流特解

### 2.4 单机（非 PD 参照）
```
node35: 1 台引擎 tp8 节点内 + DSPARK（无 prefill/decode 分离、无 KV 传输）
```
- 定位：**量化"PD 税"与"节点内 tp8 红利"的基准**（单流 224 tok/s / ITL 4.5ms）
- PD 相对单机的净代价 ≈ 单流 224→pernode 178（含 1 次 KV 跳与配对开销）

---

## 3. 流程详解

### 3.1 PD 请求全生命周期（四种拓扑通用骨架）
```
① client → router:8001 /v1/chat/completions
② router 选对: 从 prefill 池选 P、decode 池选 D (策略见 OPTIMIZATION §6.3)，
   生成 bootstrap_room (本次请求唯一标识)
③ router → P:/generate  (请求体含 room 与 D 的直达信息)
④ P 执行 prefill (chunked 分块计算 KV)
⑤ D 凭 room 向 P 的 bootstrap 服务 (:8998/route) 查询 P 的传输信息，
   建立 mooncake RDMA 通道; P 侧把 KV 逐节点推送到 D
⑥ router → D:/generate → decode 流式生成 → 回聚合到 client
⑦ room 释放; 两侧引擎回收各自缓存
```
**每一步的失败语义**：②无可用对→`Failed to select PD pair`；⑤握手失败→`Error fetching prefill
server info from bootstrap`（端点错误/引擎未就绪的典型），熔断打开后需按 `DEPLOY.md §5.2` 处置。

### 3.2 各拓扑的流程差异
| 环节 | pernode | 跨节点单引擎 | pp4-official | 单机 |
|---|---|---|---|---|
| 配对粒度 | **请求级**（4×4 池） | 单一对（大引擎） | 单一对 | 无 |
| prefill 并行 | 节点内 tp8 | tp8 跨节点 + dp4 | tp8×pp4 流水线 | tp8 节点内 |
| DP 位置 | **router 层** | 引擎内 | 引擎内 | 无 |
| KV 跳 | 1 跳跨节点 | 1 跳跨节点 | 1 跳跨节点 | 0 |
| 扩容方式 | 端点池加项 | 加节点=重排 tp 分片 | 同左 | — |

### 3.3 KV 传输路径细节
- 承载：mooncake（`--disaggregation-transfer-backend mooncake`），走 `mlx5_0` RDMA
- 关键 env：`MC_MACA_HOST_TRANSPORT=1`（**必设**，否则 `mcIpcOpenMemHandle` 全失败——MACA 传输桥）
- DSPARK 的 draft KV 不参与传输：由 decode 侧 `CommitKvProj` 从 target hidden 投影生成

### 3.4 失败与自愈流程（所有拓扑共用）
```
引擎进程异常退出 (竞态/断言)
 → LWS RecreateGroupOnPodRestart: 整组删建 (pernode=单台, 影响面 1/4)
 → 期间在途请求失败 (client/router 重试兜底)
 → (危险路径) 重建后 rank0 落点 IP 变化 → router 端点失效 → 全站 5xx 且熔断不自愈
 → 处置: 重算 leaders → set env 端点 → scale 0→1 重启 router (DEPLOY.md §5.2)
```

---

## 4. 参数详解（是什么 · 终值 · 为何）

### 4.1 并行与部署
| 参数 | 语义 | 终值 | 为何 |
|---|---|---|---|
| `--tp-size` | 张量并行度（每层切分） | 8 | 权重 34.6G/卡（tp4=69G 超 64G 上限）→ tp8 唯一可行；**pernode 型放节点内**（互联优势） |
| `--pp-size` | 流水并行 | 1（pp4 级=4） | pp 有 bubble 且与投机解码不兼容；pp4 仅用于长 prefill 特解 |
| `--dp-size` | 引擎内数据并行 | pernode=1；旧=4 | pernode 的 DP 上移 router；旧形态引擎内 dp4 配 `--enable-dp-attention` |
| `--ep-size` | 专家并行 | **1** | ⚠ decode ep>1 时 DSPARK verify graph 捕获必崩（MACA 栈限制） |
| LWS `replicas/size` | 组数×每组 pod 数 | pernode 4/1；旧 1/4 | 决定"多小引擎"vs"单大引擎"的边界 |
| router 端点池 | prefill/decode 成员表 | 4+4（IP:port） | 服务层 DP 的成员表；扩容=加项+重启 |

### 4.2 并发与调度
| 参数 | 语义 | 终值 | 为何 |
|---|---|---|---|
| `--max-running-requests` | 单引擎并发槽位 | **48**（×4=192 总） | cap 阶梯实测：16→并发 64 时 TTFT 排队崩（17s）；32→conc64 略优但 160 无余量；**48→160 并发零失败 TTFT 2.0s** |
| `--cuda-graph-max-bs` | 解码 CUDA graph 捕获上限 | **64** | ⚠ **必须 > max-running**：引擎 bs 重建仅在 `adjusted≠requested` 触发（缺陷规避，§5.1）；值本身被引擎按 cap 下调（64→48） |
| `--chunked-prefill-size` | prefill 分块 | 16384 | 引擎在 dp-attention 形态自动改 4096（MoE 内核守卫）；dp1 保持 16384 |
| `--schedule-conservativeness` | 调度保守度 | 0.6（引擎硬改 **0.18**） | 引擎对 DSv4 硬性覆写 → 实为锁定参数 |
| `--max-prefill-tokens` | 单步 prefill 上限 | 16384 | 跟随 chunked |

### 4.3 DSPARK 投机解码（收益最大项）
| 参数/env | 语义 | 终值 | 为何 |
|---|---|---|---|
| `--speculative-algorithm DSPARK` | 投机解码算法 | 开 | A/B 实测：**单流 TPOT 5.5 vs 16.6ms（3x）、吞吐 2.5x**、b128 TTFT 5.9x |
| `--speculative-dspark-block-size` | draft 块大小 | 6 | 实测 accept rate 0.78-0.83 / len 5.6-6.5（上限 7）→ 近饱和 |
| `SGLANG_DSPARK_KERNEL_COMMIT_KV_PROJ=torch` | draft KV 投影实现 | torch | triton 变体走 F.linear 对 W8A8 不适用（用户单机验证值） |
| `disable_ignore_eos` 类行为 | 输出长度控制 | — | ⚠ 端到端未生效 → 输出长度方差 ±25%，**吞吐对比必须取中位**（测量学铁律） |

### 4.4 内存与缓存
| 参数 | 语义 | 终值 | 为何 |
|---|---|---|---|
| `--mem-fraction-static` | KV 池显存占比 | prefill 0.82 / decode 0.75 | rc3 标定曲线（0.75 消 OOM 且吞吐最优；0.78 曾 OOM） |
| `--kv-cache-dtype` | KV 精度 | bfloat16 | 精度/收益平衡（fp8 需硬件+数值双重验证，未采） |
| `--page-size` | KV 页 | 64（引擎归一 **256**） | dsv4 后端强制 256 → 实际锁定 |
| `swa_full_tokens_ratio` | 混合 SWA 池比例 | 0.1 | rc3 定论（0.4→0.1 消除 268 次 retract 触发） |
| `--context-length` | 上下文上限 | 400000 | 业务值（影响 KV 预算上限而非热点路径） |
| HiCache L2（`MY_ENABLE_HICACHE`） | Host 内存缓存层 | **off**（多轮场景按需 1） | 随机负载无效应；多轮稳态 +10-30%（详见 L2 报告） |

### 4.5 传输 / 网络 / 端口
| 项 | 值 | 为何 |
|---|---|---|
| `--disaggregation-ib-device` | mlx5_0 | 单轨（双轨 A/B 未跑） |
| `--disaggregation-bootstrap-port` | 8998 | PD 握手服务；router 需以此端口注册 prefill |
| 引擎端口族 | 8000(prefill HTTP) / 8200(decode) / 5600 / 5000(dist) | hostNetwork 各节点独立 |
| `--dist-timeout` / `--watchdog-timeout` | 300 / 300 | 引擎默认（官方脚本形态为 30000/3600，两侧同即可比） |

---

## 5. 为何如此配置（决策清单）

1. **为何 PD 分离**：prefill/decode 资源特性相反；代价=1 次 KV 跳（本架构压至最小）。
2. **为何 pernode**：跨节点 tp8 的每层 A2A 是单流瓶颈——单机探测 IR 4.5ms vs 9.3ms 定音；
   引擎自包含后拓扑收益全兑现（峰值 +54%）。
3. **为何不用官方脚本模式**：路径税（4K 单流 +3.8s）+ 崩溃放大 7x（机制未定位）。
4. **为何 DSPARK 必开**：3x TPOT 收益 + 近饱和 accept。
5. **为何 cap48/graph-bs64**：cap 阶梯（16 崩/32 弱/48 全包络）+ bs 缺陷规避规则（>cap）。
6. **为何 ep=1、dp-attention 随 dp 走**：DSPARK verify graph 限制 + dp1 无需。
7. **为何 65K 场景看 pp4**：PP 流水线切长 prefill 的专属优势（pernode/dp 无此结构）。
8. **为何 L2 默认关**：随机负载零收益；多轮场景单 env 可开。
9. **老形态"2 卡/节点"是布局工件而非优化选择**（§2.2 证据）：其 75% 硬件闲置是历史演进盲区
   （共模比较掩盖）；**跨家族性能对照须带"硬件利用率"口径**——见 §2.2 警示与 §5.9 后续项。
10. **后续项（资源对齐实验）**：pernode 缩为 1+1 引擎（8+8 卡）vs 老形态（8+8 卡）同资源对照，
   可干净分离"节点内互联"的净收益——列入待办。

---

## 6. 性能画像总表（四拓扑关键对照）

| 指标 | pernode | 跨节点单引擎 | pp4-official | 单机 |
|---|---|---|---|---|
| 单流 TPOT | **5.5ms** | 9.3ms | 9.3ms | 4.5ms |
| 单流 4K TTFT | ~0.8s | 0.65s | 4.5s | 0.22s |
| 单流 65K TTFT | 13.0s | 13.2s | **5.3s** | ~17s |
| 并发峰值吞吐 | **3354 tok/s** | 2179 | ~1700-2200 | 2592(@128c) |
| conc160 TTFT | **2.0s** | 13.4s | 崩溃 | — |
| 稳定性 | 优 | 优 | 差（6-10x 崩溃） | — |

## 7. 文档索引
- 部署运维：`DEPLOY.md` ｜ 参数最优解：`OPTIMIZATION.md`（含 Router 实现 §6）
- 分析报告（sglbench docs）：`…comprehensive.md`（§9 pernode）/ `…stable-envelope…` / battery / L2
- 数据：DuckDB `data/bench.duckdb`（labels 见 OPTIMIZATION §7）
