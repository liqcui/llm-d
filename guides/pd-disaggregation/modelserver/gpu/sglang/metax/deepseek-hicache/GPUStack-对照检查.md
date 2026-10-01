# 逐项对照 GPUStack《Mooncake PD / Store 测试与验证报告》— 2026-09-26

> 前提：**同测试服务器、同 GPU 驱动/MACA 驱动**（用户确认）。因此硬件/驱动层
> 被排除，本文逐项核对**配置/参数/流程**是否存在遗漏。

## 对照表（按报告章节）

| § | 报告项 | GPUStack | 我们（hicache 方案）| 差异？ |
|---|---|---|---|---|
| 2 | Prefill 拓扑 | **PP8/TP1/DP1**（单机 8 卡）| 已测此形态（等价实验）**同样崩** | 无（已覆盖）|
| 2 | Decode 拓扑 | TP8/DP4/PP1 | 一致 | 无 |
| 3 | Master 启动命令 | 6 参数（rpc/metrics/http_metadata）| **完全一致** | 无 |
| 3 | `LD_LIBRARY_PATH=/opt/conda/lib` | 有 | 有（master pod init）| 无 |
| 3 | 端口 50051/8080/9003 | — | 一致（hostNetwork）| 无 |
| 4 | `MOONCAKE_MASTER` | `<ip>:50051` | `$MY_MOONCAKE_MASTER_SERVER_IP:$mooncake_master_port`，端口变量已定义 ✓ | 无 |
| 4 | `MOONCAKE_TE_META_DATA_SERVER` | `http://<ip>:8080/metadata` | 一致（结构同）| 无 |
| 4 | `MOONCAKE_PROTOCOL=rdma` | 有 | config.sh 有 | 无 |
| 4 | `MOONCAKE_DEVICE=mlx5_0,mlx5_1` | 有 | 一致 | 无 |
| 4 | **`MOONCAKE_GLOBAL_SEGMENT_SIZE`** | **`4gb`** | **`8gb`（MY_MOONCAKE_GLOBAL_SEGMENT_SIZE=8gb）** | **⚠ 差异 1** |
| 4 | `MOONCAKE_LOCAL_HOSTNAME` | 有 | config.sh:147 有 | 无 |
| 4 | `MC_MS_AUTO_DISC=0` | 有 | config.sh:148 有 | 无 |
| 4 | `--enable-hierarchical-cache` | 有 | 有 | 无 |
| 4 | `--hicache-ratio 2` | 显式 | 引擎默认 2.0（server_args 确认）| 无 |
| 4 | `--hicache-io-backend direct` | direct | **已改回 direct**（曾试 kernel）| 无（已对齐）|
| 4 | `--hicache-storage-backend mooncake` | 有 | 有 | 无 |
| 4 | `--hicache-storage-prefetch-policy timeout` | 有 | 有 | 无 |
| 5 | `--disaggregation-transfer-backend mooncake` | 显式传 | 引擎默认即 mooncake（server_args 确认）| 无 |
| 5 | `--disaggregation-ib-device mlx5_0,mlx5_1` | 有 | 一致 | 无 |
| 7 | **"SGLang/Mooncake compatibility workaround"** | **明确存在**（文字提及）| **未见其具体内容**（boot_files 与 r4 镜像内脚本均未见额外处理）| **⚠ 差异 2（最关键，需索取）** |
| 9 | 第一次请求 BatchPut 6000 items 成功 | ✅ | ❌ write_backup 即崩（未到 L3）| — |
| 12 | prefetch loaded=32000 | ✅ | 部分：prefetch loaded=512 成功过（小 prompt）| — |
| 16 | Store Service (`mooncake_store_service`) | ✅ | 未测（非当前阻塞）| — |
| 附 | `MXSHMEM_HCA_LIST` / `NVSHMEM_HCA_LIST` | **`mlx5_1`（单卡！）** | **`mlx5_0,mlx5_1`**（launcher 按 hca_list 回写）| **⚠ 差异 3** |
| 附 | `LLM_MOONCAKE_IB_DEVICE` / `MY_MOONCAKE_IB_DEVICE` | `mlx5_0` / `mlx5_0,mlx5_1` | 无此二变量（用 PD_MOONCAKE_IB_DEVICE 单一变量）| ⚠ 差异 4（变量体系不同，效果近似）|
| 附 | `USE_INDEX_CACHE=1` / `OMP_NUM_THREADS=1` | 有 | **待核对**（§13.6 曾说新镜像无此变量而删）| ⚠ 差异 5（低嫌疑）|
| 附 | `SGLANG_DYNAMIC_CHUNKING_SMOOTH_FACTOR=0.75` | prefill.sh 有 | r4 镜像 prefill.sh 同血统**有** | 无 |
| 附 | decode `--disable-overlap-schedule` | hicache decode 带 | 我们 decode 不需要（hicache 只在 prefill）| 无 |

## 结论：候选遗漏（按嫌疑排序）

1. **差异 2 — "compatibility workaround" 具体内容**（报告 §7 明确提及，我们未知）
   ——**最大嫌疑**；同镜像同驱动下，这可能是唯一的实质差异。**建议直接向 GPUStack
   索取该 workaround 的补丁清单/环境变量**
2. **差异 1 — `MOONCAKE_GLOBAL_SEGMENT_SIZE`：8gb vs 4gb**——segment buffer 大小
   影响 RDMA 注册区域与搬运 buffer 布局；**可立即对齐测试**（改成 4gb）
3. **差异 3 — `MXSHMEM_HCA_LIST`/`NVSHMEM_HCA_LIST`：单卡 mlx5_1 vs 双卡**
   ——SHMEM 通信路径配置不同；**可立即对齐测试**
4. 差异 4/5 — 变量体系差异与低嫌疑项，可顺带对齐

## 下一步测试计划（对齐实验，单变量）

在 hicache（r4, 单机 PP8/TP1 同形态）上依次对齐：
- 轮 1：`MY_MOONCAKE_GLOBAL_SEGMENT_SIZE=4gb`（对齐差异 1）
- 轮 2：追加 `MXSHMEM_HCA_LIST=mlx5_1` + `NVSHMEM_HCA_LIST=mlx5_1`（对齐差异 3）
- 轮 3：追加 `USE_INDEX_CACHE=1` + `OMP_NUM_THREADS=1`（对齐差异 5）
每轮：长 prompt 两连发（触发 write_backup）→ 观察是否崩溃。

⚠ 每轮测试需暂切生产 prefill（~20 分钟/轮）。
