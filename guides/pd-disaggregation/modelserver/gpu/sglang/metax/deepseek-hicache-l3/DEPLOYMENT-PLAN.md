# HiCache L2 + Mooncake L3 部署方案 — 2026-09-26

> 目标：在 `deepseek-hicache-l2`（L2-only 已验证 45x）基础上 **enable L3**，
> 对照 GPUStack《Mooncake PD / Store 测试与验证报告》+ Mooncake 官方指南
> （SGLang HiCache with Mooncake 完整指南），部署并测试真正的 L2+L3 全链路。
> 目录：`deepseek-hicache-l3/`（本目录）。状态机见 HICACHE.md §1。

---

## 1. 与 GPUStack 报告的差异分析（遗漏清单）

对照 `deepseek-hicache/GPUStack-对照检查.md`（2026-09-26 早版，其"差异"结论）：

| # | 报告项 | GPUStack | 我们 L3 方案 | 处置 |
|---|---|---|---|---|
| D1 | `MY_TMUX_ENABLE_MOONCAKE_STORE` | `'1'`（L3 总开关）| **原 yaml 缺失** | ✅ 已加 `=1`（prefill.yaml）|
| D2 | `MY_MOONCAKE_MASTER_SERVER_IP` / `MY_MOONCAKE_META_DATA_SERVER_IP` | `<master IP>`（两行同 IP）| **原 yaml 缺失** | ✅ 已加 `10.66.3.36`（master 落点 = mxgpu-3-36）|
| D3 | `MOONCAKE_GLOBAL_SEGMENT_SIZE` | `4gb`（报告 §7，PP8 → 池 32GiB）| 镜像默认 4gb（r4-hicache-l2 config.sh:154）| ✅ 设 `MY_MOONCAKE_GLOBAL_SEGMENT_SIZE=8gb` → 池 **32GiB**（= 报告量级；4gb → 16GiB）|
| D4 | 池容量语义 | 每 rank 注册 `size//tp`（mooncake_store.py:408）| 已确认（config.sh 注释 + 实测 16GiB）| ✅ 文档化（§4）|
| D5 | `MOONCAKE_LOCAL_HOSTNAME` / `MC_MS_AUTO_DISC=0` | 有 | config.sh:155-156 已 export | ✅ 无需处理 |
| D6 | `--hicache-io-backend direct` | direct | prefill.sh 硬编码 direct | ✅ 无需处理 |
| D7 | Decode 独立 Store Service（报告 §16，4GiB）| ✅ 10.66.2.14 standalone | **原方案无** | ✅ 新增 `mooncake-store-decode.yaml`（node 34，4gb）|
| D8 | Decode 全栈部署（TP8/DP4/PP1 + router）| ✅ | L3 目录已有 yaml 但未部署（与 rc3 decode 端口冲突）| ✅ 本轮部署：先 scale down rc3 decode（8200/8998 同端口）|
| D9 | `--disaggregation-transfer-backend mooncake` | 显式传 | 引擎默认 mooncake（server_args 确认）| ✅ 无需处理 |
| D10 | master `eviction_high_watermark_ratio` | 报告未提 | 官方指南推荐 0.95 | ✅ 已加（mooncake-master.yaml）|
| D11 | "SGLang/Mooncake compatibility workaround" | 报告 §7 提及、内容未知 | — | ⚠ 未解（需向 GPUStack 索取；本轮以实测为准）|

**结论：配置层差异已全部闭环（D1-D10）；唯一未解仍是 D11 workaround 内容。**

---

## 2. 与 Mooncake 官方指南的对齐 / 优化项

| 官方项 | 我们的选择 | 说明 |
|---|---|---|
| metadata service 嵌入 master（`--enable_http_metadata_server`）| ✅ 嵌入式 | 免单独部署 http_metadata_server |
| `eviction_high_watermark_ratio=0.95` | ✅ 已加 | 官方推荐；高水位触发驱逐 |
| standalone store 环境变量形式 | ✅ 采用 | `MOONCAKE_*` env + `mooncake_store_service --port=8081`；`local_buffer_size=0` 纯贡献 |
| **Dummy Client 模式**（`MOONCAKE_STANDALONE_STORAGE=1` + 本地 `mooncake_client`）| ⏭ 后续项 | 官方实验性设计：SGLang 与 RDMA/内存管理解耦，**缓存可在引擎重启后存活**（L3 真命中的最强证明）。本轮先用嵌入模式对齐报告，跑通后作为 P2 优化 |
| HugeTLB / `MC_MMAP_ARENA_POOL_SIZE` 分配器 | ⏭ 后续项 | 官方性能调优（分配延迟 1000ns→50ns）；CPU DRAM 充足、本轮聚焦功能验证 |
| PD 分离下 decode 不开 HiCache | ✅ 保持 | decode KV 经 RDMA 直传不经过 L3（报告 §2.1 同）|
| `--hicache-mem-layout` 必须 page_first/direct | ✅ page_first_direct | direct io 自动选 |

---

## 3. 目标拓扑（9 节点）

```
                  PD Router (node 32, :8001)
                        │
              ┌─────────┴─────────┐
              ▼                   ▼
        Prefill ×4 (28/29/31/36)  Decode ×4 (32/33/34/35)
        tp8/pp4/dp1, :8000        tp8/dp4/ep8, :8200 (+sidecar :8000)
        HiCache L2 + L3 开         不开 HiCache (原样最优配置)
              │                   │
              └── Mooncake TE (RDMA mlx5_0,mlx5_1) ──┘

   Mooncake Master (node 36, 10.66.3.36:50051/8080/9003)
        │
        ├── Prefill Embedded Store: 32 rank × (8gb//tp8=1GiB) = 32 GiB
        └── Decode Standalone Store (node 34, 4 GiB, :8081)   ← 本轮新增
        → Global Pool = 36 GiB
```

- prefill 拓扑由 `MY_PREFILL_PP_AUTO=1` 推导：tp=8（整除 o_groups=8）、pp=4（32 dies/tp）
- decode 保持 `0.5.12-maca...-llm` 最优镜像（1238 tok/s 配置），不改任何参数
- mooncake-master 与 store 用 `0.5.13-dsv4-adapter-r4`（与 prefill client 同血统，防 invalid rpc arg）

---

## 4. 池容量语义（已确认）

- 每 rank 注册 `MOONCAKE_GLOBAL_SEGMENT_SIZE // tp_size`（mooncake_store.py:408）
- 池总量 = Σ rank = `pp × global_segment_size`（与 TP 无关）
- 本轮：`MY_MOONCAKE_GLOBAL_SEGMENT_SIZE=8gb`，tp8/pp4 × 4 节点 = 32 rank × 1GiB = **32 GiB**
- 加 decode standalone 4 GiB → 全局 36 GiB（对齐报告 §16.3 的 32→36 验证）
- 实测基准（镜像 config.sh 注释记录）：4gb 时 `master_total_capacity_bytes=17179869184`（16 GiB）✓

---

## 5. 部署顺序（每步验证）

| # | 动作 | 验证 |
|---|---|---|
| 1 | apply `mooncake-master.yaml` | node36 上 50051/8080/9003 LISTEN；`curl :8080/metadata`；`--eviction_high_watermark_ratio` 生效 |
| 2 | apply `mooncake-store-decode.yaml` | master 容量 0 → 4 GiB；store 日志无错 |
| 3 | **scale down rc3 decode**（`kubectl scale lws decode-dsv4rc3 --replicas=0`）| 释放 node 32-35 的 8200/8998 |
| 4 | apply `prefill.yaml`（L3 env）| LWS 重建组；冷启动 ~15min；日志见 `--enable-hierarchical-cache --hicache-storage-backend=mooncake`、store mount、`fired up`；master 容量 → 36 GiB |
| 5 | apply `decode.yaml` + `services.yaml` | decode-hicache 4/4 Ready；记 leader IP |
| 6 | 更新 `router.yaml` 端点（prefill/decode leader 宿主机 IP）→ apply | `curl :8001/v1/models` 200；日志 prefill/decode 双地址 |
| 7 | apply `mooncake-store-decode.yaml`（若 2 时未做）| — |

⚠ 步骤 4 会替换现有 L2-only prefill-hicache 组（同名 LWS, RecreateGroupOnPodRestart）——
L2 缓存清空属预期。leader 漂移后 router 端点必须同步（步骤 6）。

---

## 6. 测试方案（对齐报告 §8-13）

**判据链**（L3 真命中）：
1. 长 prompt（1359 token）两连发 → 第 2 发 `#cached-token>0`（L2 命中，45x 复验）
2. `POST /flush_cache?timeout=30` → 清 prefill 本地 L1/L2（8 个 PP stage 全 flushed）
3. 第 3 发同 prompt → `#cached-token>0` 且 prefill 日志
   `HiCache prefetch success ... matched=0 loaded=N` → **L3 回读 PASS**
4. master 证据：`/metrics` 的 `Storage used` / `Keys` / BatchPut/BatchGet 计数
5. 可选强化：32K prompt（~982MB 写入 L3，报告 §8-14 同量级）

**性能对比（报告 §19 A/B/C）**：Cold vs L2 Hit vs L3 Hit 的 TTFT/prefill 时延。
若 1359-token 三连发稳定，再测 4K/16K 各一组。

**崩溃预案**：若 write_backup 阶段重现 MACA transfer kernel Xnack(0x8) 崩溃
（HICACHE.md §5）——取证（MXC/MCR 日志 + Python 栈）后回退 L2-only 配置
（删 4 个 L3 env 即可），生产保底仍是 L2-only（45x）。

---

## 7. 风险与回退

| 风险 | 影响 | 回退 |
|---|---|---|
| transfer kernel 崩溃（L3 write 路径）| 高 | 删 L3 env → L2-only（已验证可用）；证据链报 MACA |
| prefill 组重建冷启动 15min | 中 | 等待；TileLang JIT 属预期 |
| rc3 decode 被缩容后 L2 测试链路失效 | 低 | 其 yaml 未动，随时 `scale --replicas=1` 恢复 |
| 32GiB 池 × RDMA 注册（memlock）| 低 | 镜像内已是 root + hostIPC；如注册失败降 `MY_MOONCAKE_GLOBAL_SEGMENT_SIZE=4gb` |
| master/store 重启丢段数据 | 低 | 无状态重启丢缓存不丢服务（官方行为）；L3 命中测试需在数据写入后完成 |
