# DeepSeek-V4 PD 分离优化文档（2026-09-26 终版）

> 8 节点 MetaX C500 集群（MACA 3.8.1.3 驱动 / 3.9.6 内核）PD 分离部署调优全记录。
> 压测统一条件：`metax/sglang:benchmark` 镜像 bench_serving，ShareGPT，
> 512ctx/128out，100 req，rate 20（注明除外）。所有对比均为单变量实验。

## 一、结论速览

**🏆 优化后配置推荐用于生产（吞吐 +4~22%，TTFT 快 ~3x，稳定性决定性差异）：**

⚠ **2026-10-01 同日重测修正**（逐轮全记录见 `BENCHMARK-COMPARISON-2026-10-01.md`）：
09-26 记录的"厂商默认 298 tok/s / TTFT 29.9s"是**首轮 TileLang JIT 热身值**
（同日 r1=296/29.7s 与记录完全吻合）。两变体各跑 7-8 轮取稳定值（首轮/崩溃轮作废）：

| 指标 | 厂商默认拓扑 | **优化后拓扑** |
|---|---|---|
| 拓扑 | decode: tp=32/dp=32/ep=32/pp=1<br>prefill: tp=4/pp=8/dp=1 | **decode: tp=8/ep=8/dp=4/pp=1<br>prefill: tp=8/dp=4/pp=1** |
| Output 吞吐（中位） | 982 tok/s（843-1030） | **1019 tok/s（831-1254）** |
| Output 峰值 | 1030 tok/s | **1254 tok/s（+22%）** |
| Total 吞吐（中位） | 1922 tok/s | **1992 tok/s** |
| TTFT（中位） | 3220 ms（775-3779） | **1087 ms（866-2379，快 ~3x）** |
| TPOT（中位） | 43.2 ms | 41.2 ms（持平） |
| 启动就绪 | 25-40 分钟 | **~8 分钟** |
| 稳定性 | ❌ **~1 小时压测崩 2 次**（prefill rank0 illegal access, 20:05 node36 / 20:35 node31, LWS 自动重建 ~25min） | ✅ 7 轮零崩溃 |
| 结论 | ❌ 不宜生产 | **✅ 生产推荐** |

**同日对比结论（稳定值比稳定值）**：吞吐差距仅 **~1.04x（中位）/ 1.2x（峰值）**，
非 09-26 误记的 4.1x；**TTFT ~3x、稳定性（0 崩 vs 2 崩/小时）、启动速度（8 vs 25-40 分钟）
是最优解胜出的核心维度**。官方拓扑的吞吐不差，但不稳定 + 启动慢，不宜生产。

> 对比协议: 两边必须同轮次（≥第 2 轮）比; 首轮一律作废。

**厂商默认拓扑失败机理**：
- prefill `pp=8`：请求必须流经 8 个 PP stage 流水线，每 stage 有 bubble（等待/排空），
  且 `tp=4` 跨 2 节点 → 每层跨节点通信。512-token 请求的 prefill 被放大成
  **流水线化串行处理 → TTFT 29.9s**
- decode `ep=32`：256 个专家分布在 32 个 rank（4 节点），**每步 MoE A2A 全部跨节点**
  （IB 带宽瓶颈）→ TPOT 63.8ms
- decode `dp=32`：每步 `_broadcast_reqs_across_ranks` 在 32 个 rank 间广播（Gloo），
  同步开销随 rank 数增长

## 二、最终最优配置（全部参数及作用）

**镜像**：`harbor.isuanova.com/metax/sglang:0.5.12-maca.ai3.8.2.7-torch2.10-py312-ubuntu22.04-amd64-llm`
（0.5.12 引擎 + MACA 3.8.2.6 用户态，与驱动匹配；含 llm-launch 全套补丁）

### 拓扑参数（为什么如此配置）

| 参数 | 值 | 作用与意义 |
|---|---|---|
| **tp-size** | 8 | 张量并行度 = 单节点 8 卡。**作用**：模型权重、attention、MoE 在 8 卡内分片，all-reduce/A2A 全部走节点内高速互联（XGMI/NVLink），**零跨节点 TP 通信**。**约束**：tp=4 时每卡权重 277G/4=69.3G > C500 显存 63.59G 装不下；tp=8 时 34.6G/卡，剩 ~29G 给 KV+激活 |
| **ep-size** | 8 | 专家并行度。**作用**：256 个 MoE 专家均分到 8 个 rank，token 按路由结果 A2A 分发。**约束**：deepep 强制 ep=tp（引擎自动对齐），且 ep=8 使专家 A2A 全部节点内。ep=32（厂商默认）导致每步跨节点 A2A |
| **dp-size** | 4 | 数据并行度 = 4 个 replica。**作用**：请求 4 路负载均衡，每个 replica 独立完整处理请求（KV 池 ×4）。**约束**：32 卡 ÷ (tp 8 × pp 1) = 4，恰好每 replica 1 节点 → DP rank 间零通信。dp=32（厂商默认）导致每步 32 rank 广播同步 |
| **pp-size** | 1 | 流水线并行度。**作用**：PP 把层分到多 rank 流水线执行，适合训练；**推理场景每步有 pipeline bubble**（stage 等待/排空），且 sglang 断言 PP>1 与 speculative/overlap 不兼容。pp=1 消除全部 bubble |

### decode 参数

| 参数 | 值 | 作用与意义 |
|---|---|---|
| **mem-fraction-static** | 0.75 | KV cache 池大小 = init 可用显存 × f。**作用**：池越大可驻留并发序列越多 → 排队越少。**实测曲线**：0.72→620 tok/s（池小排队）、**0.75→930 tok/s**（消排队）、0.78→负载下 OOM（tp=8 权重 34.6G/卡，激活无余量）。0.75 是"消排队 vs 不 OOM"平衡点，池 ~210K tokens |
| **EAGLE draft tokens**（`decode_mtp_specific=5`） | 5 | 投机解码：draft 模型每步猜 5 个 token，一次 verify。**作用**：accept≈0.4-0.6 时每步产出 ~3 token（vs 无投机 1 个）。**实测**：3→930、5→958（最优）、6→875（verify 成本反超）。长上下文下 accept 升至 0.67-0.78（更可预测） |
| **EPLB**（`--enable-eplb --init-expert-location`） | 开 | 专家负载均衡：用预计算 expert location 文件 + 10000 轮 rebalance，消除 MoE 专家热点。**实测**：+6% 吞吐 |
| **max-running-requests** | 160（默认 40×dp4） | 引擎并发上限。**作用**：决定 batch 大小与每步同步开销的平衡。**实测**：64→798（并发过高，广播/握手开销反超）、**160→958 最优**。⚠ 0.5.12 厂商默认 specific=40（非 8） |
| **cuda-graph-max-bs** | 160（自动=max-running×dp） | CUDA graph 覆盖的最大 batch。**作用**：batch ≤160 全部走 graph（免 CPU 启动开销）。**0.5.13 血统写死 8，超过走 eager 慢 10 倍——这是 0.5.13 只有 120 tok/s 的根因之一** |
| moe-a2a-backend | deepep | DeepEP low_latency 模式，走 IBGDA RDMA 直连（400G NDR） |
| moe-runner-backend | deep_gemm | C500 上最快的 MoE GEMM 后端 |
| swa-full-tokens-ratio | 0.4 | DSv4 混合注意力（SWA 稀疏 + 全注意）中全注意 token 比例，厂商标定 |
| enable-dp-attention | 开 | dp>1 必需（引擎断言）；attention 头在 DP rank 间切分 |

### prefill 参数

| 参数 | 值 | 作用与意义 |
|---|---|---|
| **chunked-prefill-size** | 4096（×dp4=16384） | prefill 分块大小。**作用**：决定 prefill batch 调度粒度。**实测反例**：8192（×4=32768）时 TTFT 1.2s→**15.4s 暴增**（scheduler 等待超大 batch 合并，调度劣化）。4096×dp 是厂商标定 |
| max-running-requests | 256（64×dp4） | prefill 短请求无调度瓶颈，高上限保证不排队 |
| mem-fraction-static | 0.82 | 厂商硬编码：prefill 无 graph/draft，显存几乎全给 KV 池 |
| disable-cuda-graph | 开 | prefill 不抓图（厂商设计），也解释了 graph 类故障从不出现在 prefill |

### 关键环境变量

| 变量 | 值 | 作用 |
|---|---|---|
| `decode_mtp_specific` | 5（pod env） | EAGLE draft tokens。⚠ 0.5.12 血统读**环境变量**（models 的 `decode_mtp_default="${decode_mtp_specific:-3}"`），launcher 回写文件无效 |
| `SGLANG_DEEPEP_BF16_DISPATCH` | 1 | 强制 BF16 dispatch（0.5.12 脚本自带）。缺它 deepep 传 topk_weights 崩溃（0.5.13 的坑） |
| `SGLANG_STATIC_EPLB` | True | 静态预计算专家分布（厂商验证形式） |
| `SGLANG_DISAGGREGATION_QUEUE_SIZE` | 8（未动） | PD 传输队列。实测无排队迹象（#transfer-req: 0）无需调 |
| `SGLANG_DSV4_FIX_TP_ATTN_A2A_SCATTER` | False | 0.5.12 血统默认 |

## 三、双镜像对比（MACA 3.8.2 vs 3.7）

| 指标 | 3.7 版（3.7.1.13） | **3.8.2 版（3.8.2.6）** |
|---|---|---|
| 驱动兼容 | ⚠ 不匹配风险（0.5.13 在 node 33 复现 illegal access） | ✅ 匹配 |
| Output 吞吐 | 958 tok/s | **1238 tok/s（+29%）** |
| TPOT | 55ms | **36.8ms（-33%）** |
| TTFT | 1.2s | **0.82s** |

## 四、长上下文验证

| 场景 | 结果 |
|---|---|
| 4096/2048 并发 (rate 5) | **Output 1480.7 tok/s（比短上下文 +20%）**，EAGLE accept 0.45-0.60 |
| 32K 上下文 | KV 池用到 97-98% 但引擎稳定，accept 0.67-0.78（低并发 5-6 序列可行） |
| Max ITL 372ms | 罕见调度间隙非传输瓶颈，P99 25ms，无需调队列 |

## 五、镜像构建与补丁

见 `pd-disaggregation-optimize` skill §3（迁移步骤 + 4 项脚本补丁 + 血泪坑）。
⚠ 重建必须从基础镜像完整重打补丁；首轮压测偏低是 TileLang JIT 热身，取 2-3 轮稳定值。

## 六、压测方法

见 skill §1。⚠ 数据集必须本地 `--dataset-path`；bench 前确认 router 端点 =
当前 master 宿主机 IP（leader 漂移需同步，router 更新后 scale 0→1）。
