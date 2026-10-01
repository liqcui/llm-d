# DeepSeek-V4 HiCache (Mooncake L3) 方案文档 — 2026-09-26

> **⭐ 2026-09-26 晚重大结论：L2-only（不开 mooncake L3）完整可用；崩溃仅由 L3 引入。**
> 实测：1359-token prompt 两连发 —— **请求 1: 58.55s → 请求 2: 1.30s（45x）**，
> `#cached-token: 1280` 与 `sglang:hicache_host_used_tokens=1280` 精确吻合，
> L2 host 池容量 ~484 万 token，**全程零崩溃**。**生产建议先上 L2-only**；
> L3 崩溃根因定位见 §5。

> 从 `deepseek-v4-rc3-maca` 复制的 HiCache 专属部署（目录 `deepseek-hicache/`）。
> 目标：prefill 启用 HiCache 三级 KV 缓存（GPU L1 → Host L2 → Mooncake Store L3），
> 实现跨请求 / 跨实例的 KV 复用，改善长 SystemPrompt 与多轮对话场景的 TTFT。

---

## 1. 架构

### 1.1 三级 KV 缓存

```
                        请求 (相同/共享 prefix)
                              │
                              ▼
┌─────────────────────────────────────────────────────┐
│ GPU HBM (L1)    RadixAttention 前缀树 (UnifiedRadixCache) │
│                 容量: mem-fraction-static 划定的 KV 池     │
└───────────────┬─────────────────────────▲───────────┘
                │ write_backup (写回)      │ prefetch (预取)
                │ GPU→Host DMA            │ Host/L3→GPU DMA
                ▼                         │
┌─────────────────────────────────────────────────────┐
│ Host DRAM (L2)  hicache-ratio × GPU 池大小的 host 池     │
│                  (cache_controller 管理, write_through)  │
└───────────────┬─────────────────────────▲───────────┘
                │ batch_set (写)            │ batch_get (读)
                ▼                         │
┌─────────────────────────────────────────────────────┐
│ Mooncake Store (L3)  全局 KV 池 (RDMA)                  │
│   Master (元数据/RPC) + 各节点 Client Segment (DRAM 注册)  │
└─────────────────────────────────────────────────────┘
```

### 1.2 与 PD 分离的集成（SGLang 官方两种模式）

1. **仅 Prefill 开 HiCache**（我们的选择）：prefill 节点间共享 KV 缓存——
   适合 SystemPrompt 场景（多个 prefill 实例对同一长系统提示复用 KV）
2. **全量 HiCache + decode 异步卸载**：decode 侧加
   `--disaggregation-decode-enable-offload-kvcache`，把 decode 的 KV 卸载供
   prefill 复用——适合多轮对话（下一阶段可加）

### 1.3 多轮请求的完整数据流

```
第一次请求（长 prompt）
  → prefill: 前缀树未命中 → 正常计算 KV
  → 计算完成 → write_backup: GPU L1 → Host L2
  → (write_through 策略) → Mooncake L3 (batch_set)

flush_cache（或 L1 淘汰）
  → 本地 L1/L2 清空, L3 保留

第二次相同 prompt
  → prefill: L1 未命中 → 查 L2/L3 → 命中
  → prefetch: L3/L2 → GPU (loaded=N tokens)
  → 日志: "HiCache prefetch success ... loaded=512"
  → #cached-token=N → 跳过 KV 计算直接进入 PD 传输 → decode 续生成
```

---

## 2. 核心组件与原理

| 组件 | 角色 |
|---|---|
| **UnifiedRadixCache** | DSv4 混合 attention（full+swa 多池）专用的统一前缀树。DSv4 **必须**用它（`SGLANG_ENABLE_UNIFIED_RADIX_TREE=1`）——HiRadixCache 明确拒绝非 MHA/MLA/NSA 模型（`hiradix_cache.py:98`）|
| **HybridCacheController** | L1↔L2 搬运调度：`write_backup`（写回线程）/ `prefetch`（预取线程）/ `move_hybrid_indices`（索引搬运）|
| **StorageBackend (mooncake)** | L3 读写：`batch_set/batch_get/exist_key`，RDMA 传输 |
| **Mooncake Master** | L3 全局元数据 + 段管理（`mooncake_master --rpc_port=50051`）；各 client 注册 DRAM segment（`MOONCAKE_GLOBAL_SEGMENT_SIZE`）|
| **write_through 策略** | KV 写到 L2 时同步写 L3（保证 flush 后可回读）|
| **prefetch_policy=timeout** | L3 预取超时策略：平衡"完整预取"与"尽力而为"，**mooncake 场景官方推荐** |

---

## 3. 参数详解与配置理由

### 3.1 HiCache 核心参数

| 参数 | 官方最佳实践 | 我们 | 为何如此配置 |
|---|---|---|---|
| `--enable-hierarchical-cache` | 开 | 开（env `MY_TMUX_ENABLE_MOONCAKE_STORE=1` 联动）| HiCache 总开关；厂商脚本里 L2/L3 由同一 env 控制 |
| `--page-size` | 64 | **256（DSv4 强制）** | 非可选：DSv4 attention backend 启动时自动改为 256（`Use dsv4 attention backend..., setting page_size to 256`），env 回写会被覆盖。64 是通用最佳实践，但 DSv4 的页管理需求更高 |
| `--hicache-ratio` | 2 | **2** | L2 host 池 = 2× GPU KV 池（CPU DRAM 充裕的前提下的通用值）|
| `--hicache-size` | 0（用 ratio）| **0** | 用 ratio 动态计算，不写死绝对值 |
| `--hicache-mem-layout` | page_first_direct | **page_first_direct**（direct io 时引擎自动）| direct I/O 后端专用布局，零拷贝兼容 fa3 |
| `--hicache-io-backend` | direct（或 kernel）| **kernel（诊断后改）** | L1↔L2 搬运 I/O 后端。direct=零拷贝但触发 MACA transfer kernel 崩溃（见 §5）；kernel=经 kernel 拷贝更保守 |
| `--hicache-write-policy` | write_through | **write_through** | 写 L2 时同步 L3——flush 后能回读的前提 |
| `--hicache-storage-backend` | mooncake | **mooncake** | 官方 mooncake 集成示例配置 |
| `--hicache-storage-prefetch-policy` | timeout | **timeout** | mooncake 场景官方推荐（best_effort 可能不完整、wait_complete 阻塞久）|

### 3.2 Mooncake 相关（config.sh 自动 export）

| 变量 | 值 | 说明 |
|---|---|---|
| `MOONCAKE_MASTER` | `<master_ip>:50051` | master RPC |
| `MOONCAKE_TE_META_DATA_SERVER` | `http://<master_ip>:8080/metadata` | 元数据 HTTP |
| `MOONCAKE_PROTOCOL` | `rdma` | RDMA 传输 |
| `MOONCAKE_DEVICE` | `mlx5_0,mlx5_1` | HCA |
| `MOONCAKE_GLOBAL_SEGMENT_SIZE` | `8gb` | 全局段总量；**每 rank mount = 8gb ÷ tp8 = 1GiB**（mount 日志 1GiB 是正常的）|

### 3.3 拓扑选择

- **prefill: tp=8 / pp=4 / dp=1**（`MY_PREFILL_PP_AUTO=1` auto_pp 推导）——GPUStack 验证的 hicache 配方。
  推导规则：tp = 整除 o_groups(8) 的最大值 = 8；pp = nnodes×dies/tp = 4。
  ⚠ 不能沿用非 HiCache 的 tp=8/dp=4（hicache 装配器 + PP 的分层池需要此形态）
- **decode: 不开 HiCache**（保持最优配置 tp=8/dp=4）

### 3.4 环境约束类

| 项 | 值 | 理由 |
|---|---|---|
| `SGLANG_ENABLE_UNIFIED_RADIX_TREE` | 1 | DSv4 必须（见 §2）|
| `CUDA_LAUNCH_BLOCKING` | 1（诊断中）| MACA transfer kernel 竞态 workaround（见 §5）|

---

## 4. 部署形态（异构引擎组合）

| 组件 | 镜像 | 为何 |
|---|---|---|
| prefill ×4 | `0.5.13-dsv4-adapter-r4-hicache` | GPUStack hicache 适配版（完整 L2+L3）+ 我们的 io-backend env 补丁；MACA 3.8.1.4 匹配集群驱动 |
| decode ×4 | `0.5.12-maca.ai3.8.2.7-...-llm` | 最优配置（1238 tok/s），dec 不需要 hicache |
| mooncake-master | `0.5.13-dsv4-adapter-r4` | **必须与 prefill client 同版本**（跨版本 master/client → `RPC call failed: invalid rpc arg` → store 初始化失败 error -900）|
| router | `v0.5.12-glm5-rc4-pd` | 专用 sglang_router 镜像；模型镜像的 router 无 GPU 会崩 CUDA init |

PD 协议跨版本兼容（prefill 0.5.13 ↔ decode 0.5.12）经端到端验证 ✓。

---

## 5. 崩溃根因：MACA transfer kernel 竞态（阻塞中）

### 现象
长 prompt 请求**完成后**（KV write_backup 阶段）稳定崩溃：

```
[MXC][E] memory violation(0x4): memory access offset is negative, out of bounds, or misaligned
[MCR][E] trapping: kernel name: transfer_kernel_impl
[MCR][E] Xnack(0x8) exception → mcGetDevice: Returned mcErrorIllegalAddress

Python 栈（事发线程）:
  process_batch_result_disagg_prefill → maybe_cache_unfinished_req
  → unified_radix_cache.write_backup
  → hybrid_cache_controller.write → start_writing → move_hybrid_indices
  → cache_controller.py:780: host_indices.to(self.device, non_blocking=True)   ← 崩溃点
```

### 定性
HiCache 的 **host→device 索引搬运 kernel（MACA `transfer_kernel_impl`）触发
Xnack 页表异常**——与 GPUStack 团队文档 §4.6 记录同族（他们观测到
`xnack_error(0x8) + ATU invalid_xvm_pde`，并验证：**仅加 `CUDA_LAUNCH_BLOCKING=1`
（kernel 串行化）即不复现** ⇒ 属**缺同步的竞态**，而非缓冲区尺寸错误）。

### 验证实验记录（2026-09-26 晚）

| 实验 | 配置 | 结果 |
|---|---|---|
| 形态 A | tp=8/pp=4/dp=1（跨 4 节点）| ❌ write_backup 崩溃（transfer kernel Xnack）|
| 形态 B | **pp=8/tp=1/dp=1（单机 1 节点, GPUStack 原配方）** | ❌ **完全相同的栈崩溃**——**排除拓扑形态因素** |
| io-backend | direct 与 kernel 均试 | ❌ 同样崩溃——排除 IO 后端因素 |
| CUDA_LAUNCH_BLOCKING=1 | prefill 加该 env | ❌ **不可用**：hicache 初始化卡死 >25min（引擎无进展），已回退 |
| **L2-only（0.5.12）** | 0.5.12-maca...-llm-hicache（LWS 独立方案 `deepseek-hicache-l2/`）；补丁化 `enable_hierarchical_radix_cache` 开关；无 mooncake | ❌ **warmup 即崩**：`deepseek_v4.py:1156 attn_backend._maybe_upgrade_forward_metadata` → `AttributeError: 'HybridAttnBackend' object has no attribute ...`——**0.5.12 血统 hicache 的第二处代码缺口**（hybrid backend 方法缺失）→ **0.5.12 走 hicache 路线彻底不可行** |
| env 全对齐对照 | hicache prefill env vs GPUStack `maca-sglang-hicache-ds-prefill-custom` | ✅ **已完全对齐**（MACA_DIRECT_DISPATCH/SMALL_PAGESIZE/GRAPH_LAUNCH_QUEUE_POLICY/PYTORCH_PG_STREAM 等全套均在——且崩溃时已生效）→ **排除 env 缺失因素** |

**因此，与 GPUStack 报告跑通状态的剩余差异最终收敛为**：
1. **硬件/驱动栈环境层**（同为 C500 但与他们的驱动/MACA 版本组合不同；报告未注明其具体版本）
2. 他们的 boot_files 注入脚本与我们镜像内脚本一致（同血统 r4），无实质差异
3. 他们报告的 workaround 在 boot_files 可见部分中未体现额外内容

**触发路径**（跨形态一致）：`_inc_hit_count`（KV 命中计数）→ `write_backup`
（L1→L2 写回）→ `move_hybrid_indices` → `host_indices.to(device)` → MACA
`transfer_kernel_impl` → Xnack(0x8)。

### 当前处置
- 崩溃证据链完整（MXC/MCR 内核日志 + Python 栈 + py-spy dump）→ 可直接向 MACA
  团队报障
- **建议下一步**：向 GPUStack 团队确认其验证环境的驱动/MACA 版本与我们的
  （内核 3.9.6 + 用户态 3.8.2.6 + SDK 3.8.1.3）的差异

---

### 5.1 ⭐ 2026-09-27 L3 全栈复测：L2 全通, L3 崩溃点迁移到 PD 传输路径

**部署**（deepseek-hicache-l3 目录, 本轮完整形态）:
- prefill ×4: r4-hicache-l2 镜像, tp8/pp4/dp1, `MY_ENABLE_HICACHE=1` +
  `MY_TMUX_ENABLE_MOONCAKE_STORE=1` + `MY_MOONCAKE_MASTER_SERVER_IP/META_DATA_SERVER_IP=10.66.3.36` +
  `MY_MOONCAKE_GLOBAL_SEGMENT_SIZE=8gb` → 池 32GiB
- decode ×4: 0.5.12-llm 最优配置（tp8/dp4, 无 hicache）✓
- mooncake-master (node36, eviction_high_watermark_ratio=0.95) + **decode standalone store**
  (node34, 4GiB, `mooncake_store_service` + `MC_MS_AUTO_DISC=0` + **privileged**) → 全局池 **36 GiB** ✓
- 引擎参数全对齐: `enable_hierarchical_cache=True, hicache_storage_backend=mooncake,
  prefetch_policy=timeout, mem_layout=page_first_direct, io_backend=direct` ✓

**实测（1359-token prompt, 经 router）**:

| 请求 | 结果 | 结论 |
|---|---|---|
| ① 冷 | 57.95s / prompt=1236 | 冷 prefill 基线（与 L2-only 58.55s 一致）|
| ② L2 命中 | **1.49s** | L2 45x 复现 ✓ |
| flush | `Cache flushed` ✓ | L1/L2 清空 |
| ③ L3 判据 | **HTTP 500 崩溃** | L3 路径仍阻塞 ✗ |

**新崩溃证据（node29 旧 rank1 日志, 00:27:30）**:
```
[MXC][E] memory violation(0x4): memory access offset is negative, out of bounds, or misaligned
[MCR][E] mcModuleLaunchKernel: Returned mcErrorIllegalAddress
trapping: kernel name: mcblas__Mck_bf16gemm_tn_128x128x128_...   ← bf16 GEMM, 非 transfer_kernel_impl!
terminate called ... c10::AcceleratorError: CUDA error: an illegal memory access
Fatal Python error: Aborted
  .../sglang/srt/disaggregation/mooncake/conn.py:1194 in transfer_worker   ← TE 传输线程
```
- rank1 (node29) abort → PP 组 p2p 断开 → rank0 `Scheduler hit an exception:
  Connection closed by peer [10.66.3.29]` → SIGQUIT → 整组重建（RecreateGroupOnPodRestart）
- decode 侧: `Decode handshake failed ... Aborted by AbortReq`

**定性**: 与 §5 同为 MACA `memory violation(0x4)` 家族, 但**触发点迁移**:
write_backup 的 `transfer_kernel_impl` → ③ 的 **L3 prefetch 后前向 GEMM 读到非法地址**
（prefetch 写坏 GPU KV 池内存 ⇒ 后续 GEMM 越界）; TE transfer_worker 线程为崩溃时活跃线程。
⇒ 仍是 **L3 路径 buffer/内存布局问题**（嵌入 store + 引擎同进程, 与 MACA 原生栈的
兼容缺陷）, L2-only 同请求零崩溃（对照）。

**测试工具**: `metax/tools/hicache-test/`（hicache_test.py + analyze.py + README.md）。

### 5.2 ⭐ 2026-09-27 完整实验矩阵 —— L3 竞态定性（多轮实测）

**L3 功能链路本身是通的**（独立两轮均验证）:
```
flush 后 → HiCache prefetch success ... matched=0 loaded=1024   (8 TP rank, 全 PASS)
master: BatchPut Item=96 / Storage 31.57MB / Keys 128            (L3 写入 ✓)
        ExistKey=992 / BatchGet Item=480                         (L3 查询/回读 ✓)
```
请求③ 经 flush 后从 L3 回读 1024 token, 命中路径完整。**瓶颈不在功能, 在命中后的
稳定性**。

| 实验 | 配置 | 请求③ 结果 | 结论 |
|---|---|---|---|
| E1 嵌入默认 | r4-hicache-l2 + store 开（干净 master）| ✅ 200, 12.7s, L3 命中 | L3 可用 |
| E2 同配置第 2 轮 | 同上, 复测 | ❌ 500: decode handshake/AbortReq + PP p2p 断开（无 MXC 记录, 不同签名）| **间歇性崩溃** |
| E3 干净 master 重启后 | master+store 重启清残留 | ✅ 200, L3 命中 | 不根治, 只是运气 |
| E4 `CUDA_LAUNCH_BLOCKING=1` | 镜像原样 + env | ⚠️ 请求③ 超时 300s: prefetch 成功但引擎**挂死**（`_pp_commit_comm_work` p2p wait + detokenizer 无心跳 >20min）| 竞态抑制但死锁, 不可用 |
| E5 Dummy Client | `MOONCAKE_STANDALONE_STORAGE=1` + `MOONCAKE_CLIENT` | ✋ 镜像内 SGLang 0.5.13 不支持: 要求 `MooncakeHostTensorAllocator`（raise RuntimeError）| 需升级 mooncake/SGLang |

**其它发现**:
- boot 死锁（world-group broadcast `_sync_bootstrap_port_across_nodes`, 无超时永久挂）
  —— 崩溃重建后偶发, 干净重启 mooncake-master+store 可解; 与 CUDA_LAUNCH_BLOCKING 无关
  （早前 "CUDA_LAUNCH_BLOCKING 卡死 >25min" 实为同一 boot 死锁, 已澄清）
- prefill 组每次重建 leader 会漂移（本次 28→36→31）, router `PD_PREFILL_ENDPOINTS`
  必须同步（否则请求挂死）; LWS 标签轮询到随机节点
- `mooncake_store_service` 必须 `MOONCAKE_CONFIG_PATH` 指向 JSON + `privileged`
  （否则容器看不到 /dev/infiniband → 0 HCA 退 TCP）+ `MC_MS_AUTO_DISC=0`

**最终判定**: L3 在 MetaX C500 + MACA 栈上**功能可用但不可生产** —— 嵌入模式下
memory-violation 竞态（间歇崩溃, GPUStack 同类问题）, 官方解耦方案（Dummy Client）
需升级 SGLang/mooncake（镜像级改动）。**生产保底: L2-only（45x 稳定）**。
崩溃证据链完整, 可报 MACA: ① memory violation(0x4)+mcErrorIllegalAddress+GEMM kernel
② E1 成功/E2 崩溃 的对照 ③ GPUStack 报告同类 (xnack_error + CUDA_LAUNCH_BLOCKING 复现抑制)。

---

## 6. 验证与压测结果

### 5.3 ⭐ 2026-09-27 Dummy Client 完整攻坚（官方解耦方案实录）

目标: 按 Mooncake 官方文档实现 Dummy Client (SGLang → 本地 Real Client 127.0.0.1:50052),
解耦 RDMA/内存管理以规避 §5.2 竞态; 并补齐 store service 全组件。

**镜像工程** (`0.5.13-dsv4-adapter-r4-hicache-l2-mc013`, podman 本机构建):
- 源码: GitHub 不可达 → 经 bench pod curl codeload tarball 中转; yalantinglibs 同法 +
  补丁 `FindYLT.cmake` 绕过 FetchContent 用预置源码
- 构建: `-DUSE_MACA=ON` (官方 MetaX 支持); 依赖清单 = 官方 dependencies.sh 全量
- 踩坑修复: ① pybind11 submodule 缺失(补源) ② `ASCEND_GITHUB_MIRROR_URLS` 镜像前缀
  ③ OpenSSL3.3 (conda libssl) → patchelf --force-rpath 指系统库 ④ auditwheel `.libs`
   RPATH 必须保留 (`$ORIGIN/../mooncake_transfer_engine.libs`)
- 产出: mooncake_client/mooncake_master 0.3.13 (MACA) + 新 python 包
  (MooncakeHostMemAllocator/setup_dummy) ✓

**配套组件** (全部就绪):
- mooncake-master 0.3.13 (`/usr/local/bin/mooncake_master`, 注意 /opt/conda/bin 是旧 0.3.6!)
- mooncake-client DaemonSet ×4 (prefill 节点, Real Client, **默认 host=0.0.0.0** ——
  设 POD_IP 会只绑节点 IP 导致 127.0.0.1 连接被拒; 段 64GB×4)
- mooncake-store-decode (node34, 4GB) → 全局池 **260 GB** / Clients 5 ✓

**SGLang 侧补丁** (`patch_metax_dsv4_standalone.py`): DSv4 混合池 anchor=LogicalHostPool
(allocator=None) 导致 standalone_storage 硬检查误判 → 改为检查实体 buffer 子池
(与同文件 register_mem_pool_host 对逻辑锚点的既有处理一致)。

**功能验证**: dummy client 全链路 WORK ✓ —— flush 后 `#cached-token: 1024`,
8 TP rank `HiCache prefetch success matched=0 loaded=1024` (从 L3 回读)。

**卡点 (两个独立的平台级问题)**:
1. **新 mooncake 0.3.13 的 MACA TE 跨节点 PD 传输坏**: `submitTransfer failed ... 
   "device memory not registered"` / session 挂死; 独立 TE 对测 (同版本两端) 复现挂死。
   旧 0.3.6.post1 (MetaX MACA 重建) 的 PD 传输全天正常 → **上游新 TE 的 MACA 支持有回归**
2. **混合方案 (旧 engine.so + 新 store) 仍崩**: 首次请求 forward 中
   `Triton Error [MACA]: an illegal memory access` (per_token_quant_int8, MoE) ——
   与 §5.2 同族: **L3 写回路径间歇性踩坏 GPU 内存, 嵌入/Dummy 两种模式都逃不掉**

**最终结论**: Dummy Client + store service 架构在本环境**功能打通但受 MACA 平台
非法访存阻塞**; 且新 mooncake 的 MACA TE 不可用于 PD。生产保底仍是 **L2-only**;
L3 需 MACA/GPUStack 修复 (证据链: 本文档 + TROUBLESHOOTING)。

### 5.4 ⭐ 2026-09-27 晚 Dummy Client 终版测试（干净镜像，最终闭环）

在 5.3 基础上做了最终收敛:

**镜像**: `mc013` = r4-hicache-l2 + **旧 0.3.6 MACA engine.so**（PD 传输可用）
+ 新 0.3.13 store/mooncake_client（Dummy L3）+ DSv4 standalone 补丁。
(试过的错误分支: shm_helper 加 cudaHostRegister —— SGLang `alloc_with_host_register`
已自行注册, 双重注册致 boot 崩, 已撤销; 新 TE engine.so PD 传输坏, 已换回旧版)

**实测（干净 Dummy 全栈, 260GB 池/Clients 5）**:

| 请求 | 结果 | 结论 |
|---|---|---|
| boot | ✅ store `setup successfully` + `warmup successfully` + fired up | **Dummy 全栈启动打通** |
| ① 冷 | ✅ **53.8s** | **PD 传输工作（旧 TE ↔ 旧 TE）** |
| ② L2 | ✅ **1.878s (28.6x)** | L2 命中 ✓ |
| flush | ✅ | — |
| ③ L3 | ❌ 500（PP 组崩）| 平台 bug |

**③ 崩溃根因（决定性证据, 20:06:08）**:
```
[MXC][E] memory violation(0x4): ...
[MXC][E] xnack(0x8): kernel causes atu address translation error
[MCR][E] mx_trapProcess.cpp: trapping pipeID=2,queueID=0
→ rank 死 →  gloo "Connection reset by peer" → PP 组重建
```
**与 GPUStack 报告 §4.6 记录完全同款**（`xnack_error(0x8) + ATU invalid_xvm_pde`）。

崩溃现场线程栈（补充证据）:
- trapping 内核含 **`int8_paged_mqa_logits_n1_kernel`**（MLA 稀疏注意力读 KV 页）
  + `_dsv4_build_unified_prefill_indices_kernel`（KV 索引构建）
  + `_per_token_quant_int8` / mcblas GEMM / `hash_topk`
- Fatal 时刻: `jit_kernel/dsv4/gemm.py:24 linear_bf16_fp32` 与 `moe.py:133 hash_topk→torch.empty`
  （异步错误在后续 API 爆出）; `backup_thread_func`(L3 写回线程)处于 idle ——
  崩溃发生在前向**读 KV 页**时, 污染源指向 KV 页内存（L3 写回 / shm host 池路径）

**最终判定**:
1. **Dummy Client 架构本身完全可用**（boot/store/PD/L2 全通, 28.6x）
2. **L3 请求路径撞 MACA 平台 bug（xnack 0x8 + ATU）—— 嵌入模式与 Dummy 模式
   同一根因, 与架构无关**; GPUStack 靠未公开的 "compatibility workaround" 绕过
3. 排障沿线另发现两处需注意: (a) 新 mooncake 0.3.13 的 MACA TE 跨节点传输回归
   (b) 偶尔的 MCCL "wrong magic" 洪泛 + boot 期组通信死锁（环境性偶发, 重启恢复）

---

### 6.1 功能验证 ✓

| 项 | 结果 |
|---|---|
| 端到端推理（非 HiCache 路径）| ✅ via router（prefill r4 → decode 0.5.12）|
| Mooncake master 连接 | ✅ segment mount 成功（1GiB/rank = 8gb÷tp8）|
| **HiCache prefetch** | ✅ `HiCache prefetch success completed_local=512 loaded=512`（KV 从 host/L3 加载成功）|
| L3 写入路径 | ✅ 到达 write_backup（随后触发上述崩溃）|

### 6.2 压测结果

**HiCache 完整压测（TTFT 对比 / L3 命中率）因 §5 崩溃阻塞，尚未产出数据。**

参照 GPUStack 报告（同栈、r4 系镜像）的实测参考：
- 32K prompt：KV ≈ 982 MB 写入 L3，第二次相同请求 `loaded=32000` + `#cached-token=32000`，L3 回读成功
- L3 写/查/读/预取全链路 PASS（其环境 HCAs/配置已调通）

### 6.3 与非 HiCache 的对比

| 维度 | **非 HiCache**（deepseek-v4-rc3-maca 部署）| **HiCache**（本方案）|
|---|---|---|
| 镜像/引擎 | 0.5.12-maca.ai3.8.2.7-llm 单引擎 | 异构：prefill r4(0.5.13) + decode 0.5.12 |
| 拓扑 | prefill tp8/dp4/pp1；decode tp8/dp4 | prefill tp8/pp4/dp1（hicache 配方）|
| KV 复用 | 仅 GPU L1（max-tokens 内的前缀命中）| **L1 + Host L2(2×) + Mooncake L3(跨实例)** |
| 长 SystemPrompt TTFT | 每次冷 prefill（全量 KV 计算）| 理论：L3 命中时跳过 KV 计算（GPUStack 报告 32K 场景回读成功）|
| 多轮对话 | decode 各自持有 | 未来：decode offload 后可跨轮复用 |
| **实测吞吐（512/128）** | **1238 tok/s / TTFT 0.82s / TPOT 36.8ms**（100 req 压测）| **阻塞中（待 §5 解决后压测）** |
| 压测（4096/2048）| 1481 tok/s / TTFT 0.58s | 同上 |
| 生产可用性 | ✅ 已跑通稳定 | ⚠ 功能链路通、写回路径崩溃阻塞 |
| 资源开销 | — | +host DRAM（2× GPU KV 池）+ L3 段注册（8gb/实例）+ master 组件 |

**结论（当前）**：
- **非 HiCache 方案是当前生产最优**（1238 tok/s，稳定，文档/压测齐全）
- **HiCache 方案功能链路已打通**（prefetch/L3 全路径验证），但**被 MACA 原生栈
  transfer kernel 竞态阻塞**——修复前不具备生产价值
- HiCache 的收益场景是**长 SystemPrompt / 多轮对话的 TTFT**（跨请求 KV 复用），
  而非本轮 512/128 短上下文吞吐基准——需按 §7 的 A/B/C 三组场景对比

---

## 7. 下一步

1. **完成 blocking 验证**：确认 `CUDA_LAUNCH_BLOCKING=1` 下长 prompt
   flush→L3 回读不再崩（预期：不崩 ⇒ 确认竞态定性）
2. **精细化同步替代**：在 hicache 的搬运路径上补显式 event/stream 同步
   （替代全局 blocking，恢复性能）
3. **报障 MACA/GPUStack**：栈已完整（transfer_kernel_impl + Xnack + 调用链）
4. **场景化压测**（参照 GPUStack 报告 §19）：
   - A. Cold Prefill（无缓存）
   - B. HiCache L2 命中（Host→GPU）
   - C. Mooncake L3 命中（Store→GPU）
   统一 4K/16K/32K/64K 输入，记录 TTFT / L3 回读延迟 / 读写带宽
5. **L3 容量解耦**：decode 节点独立 Store Service 贡献 DRAM（Global Pool 扩容，
   参照 GPUStack 报告 §16 已在其环境验证）
