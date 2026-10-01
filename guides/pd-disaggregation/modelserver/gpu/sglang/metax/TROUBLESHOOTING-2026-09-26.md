# DeepSeek-V4 PD / HiCache 排障手册（2026-09-26）

> 覆盖 0.5.12/0.5.13 时代的全部实测踩坑（场景 A 生产 PD + 场景 B/C HiCache）。
> 旧文 `TROUBLESHOOTING.md`（GLM/rc3 时代 §1-§13）仍有效，本文与其互补。
> 相关：`BEST-PRACTICE.md`（场景配置矩阵）、`deepseek-hicache/HICACHE.md`（HiCache 详解）。

---

## 速查表（症状 → 处置）

| # | 症状 | 一行处置 | 详见 |
|---|---|---|---|
| 1 | pod Pending | 查标签/端口占用/节点资源 | §1.1 |
| 2 | router CrashLoop（CUDA init failed）| 换 `v0.5.12-glm5-rc4-pd` 镜像 | §1.2 |
| 3 | 引擎"卡住">15min 无 fired up | **正常**（TileLang JIT 冷启动）| §1.3 |
| 4 | 组反复重建 | 查首个崩溃 rank 的真错误 | §1.4 |
| 5 | 改了镜像内容节点不生效 | containerd digest 缓存 → **换新 tag** | §1.5 |
| 6 | `Fatal: Unsupported SGLang version` | common.sh 白名单加版本 | §2.1 |
| 7 | `missing ip/jq` | apt 装 iproute2 jq curl | §2.2 |
| 8 | `low_latency_dispatch() got topk_weights` | 加 `SGLANG_DEEPEP_BF16_DISPATCH=1` | §2.3 |
| 9 | `multi-node data parallel ... unless dp attention` | prefill 补 `--enable-dp-attention` | §2.4 |
| 10 | `HiRadixCache only supports MHA/MLA/NSA` | 加 `SGLANG_ENABLE_UNIFIED_RADIX_TREE=1` | §2.5 |
| 11 | `deepseek_v4_c4_state state_pools must not contain None` | 用 r3+ 镜像（含装配器 patch）| §2.6 |
| 12 | `'HybridAttnBackend' object has no attribute ...` | 删 `--decode-attention-backend` / 勿用 0.5.12 走 hicache | §2.7 |
| 13 | `shape '[4, 0, -1]' is invalid` | tp 必须整除 o_groups=8；开 auto_pp | §2.8 |
| 14 | launcher 摘要打印一半进程消失 | `_show_var` 加 `\|\| true` | §2.9 |
| 15 | `RPC failed: invalid rpc arg` / store -900 | master/client **同版本** | §3.1 |
| 16 | `Failed to connect port 8080` / store -600 | master 未起/不在（先起 master）| §3.2 |
| 17 | `Failed to get fsdir from master` | 两个 MOONCAKE_*IP env 成对改 | §3.3 |
| 18 | EPLB 没生效 | 变量名核对（`decode_eplb_file_specific`）+ models 文件需有定义行 | §3.4 |
| 19 | **`Xnack(0x8)`/`mcErrorIllegalAddress` 于 write_backup** | **L3 专用，L2-only 绕行**（详见文）| §4.1 |
| 20 | 负载下 `illegal memory access` 泛发 | 查 MACA 用户态 vs 驱动匹配 | §4.2 |
| 21 | `CUDA_LAUNCH_BLOCKING=1` 后初始化卡死 | **不可用**，勿采用 | §4.3 |
| 22 | 首轮压测数字偏低 | TileLang JIT 热身，取 2-3 轮 | §5.1 |
| 23 | EAGLE/MTP 没开 | 0.5.12 读 env `decode_mtp_specific` | §5.2 |
| 24 | max-running 与预期不符 | 0.5.12 默认 40（不是 8！）| §5.3 |
| 25 | 压测脚本 HuggingFace 下载失败 | 本地 `--dataset-path` | §5.4 |
| 26 | router 请求超时/挂死（health 200）| 后端填**宿主机 IP**（非 ClusterIP）| §6.1 |
| 27 | leader 漂移后连不上 | 同步 router 两个 IP + scale 0→1 | §6.2 |
| 28 | `kubectl apply -f` 部署"丢失" | 缺 `-n` 落到 default namespace | §6.3 |
| 29 | hostPath 日志像幽灵/多个实例混淆 | 按时间戳甄别（日志累积）| §6.4 |

---

## 一、启动 / 调度类

### 1.1 pod Pending
```
Warning FailedScheduling: 1 node(s) didn't have free ports / N nodes didn't match node affinity
```
- **端口**：hostNetwork 固定端口被同角色旧 pod 占用 → 等旧组终止或 `scale/deploy` 重建
- **亲和**：节点标签未打（`metax-sglang-pd-{prefill,decode,router}-{dsv4rc3,hicache}*`）→ 逐一核对（每方案标签互斥）
- **资源**：节点被其他方案占满

### 1.2 router CrashLoop（`CUDA driver initialization failed`）
- **根因**：模型镜像（0.5.13+ 血统）的 sglang_router 启动强依赖 CUDA init，router pod 无 GPU
- **解决**：router 用专用镜像 `harbor.isuanova.com/metax/sglang:v0.5.12-glm5-rc4-pd`
  （旧镜像如 0.5.12-dsv4-c500-llm 不崩，3.8.2.7 血统崩）

### 1.3 引擎冷启动"卡住"（>15 分钟）
- **正常！** 手册实测：冷启动 ~9-15 分钟，其中 **TileLang 首次 JIT 编译占 ~5 分钟**
- 判据：`ss -lntp` 端口在 LISTEN / 日志有推进（非完全静止）→ 等待即可
- 探针未过属正常（readiness 在 fired up 后才通过）

### 1.4 组反复重建成循环
- LWS `RecreateGroupOnPodRestart`：**任一 worker 失败 → 整组重建**（正常机制）
- 现象：pod AGE 短且不断重置；**别只看 rank0**——rank0 可能一直健康，是其他 rank 触发
- 排查：按**时间戳**看各 rank 日志的**首个**真错误（Glo0 `Connection reset` 等都是级联）

### 1.5 镜像内容更新后节点不生效（digest 缓存）
- 现象：同 tag 重推新镜像，pod 仍跑旧内容（`imageID` 核对发现）
- **解决（本集群已验证）**：**换新 tag** 推送（containerd 对同 tag 的 digest 解析有缓存窗口）
- 核对：`kubectl get pod -o jsonpath='{.status.containerStatuses[0].imageID}'`

## 二、脚本 / 引擎启动类

### 2.1 `Fatal: Unsupported SGLang version: vX`
- 厂商 common.sh 白名单检查（rc3 脚本只认 0.5.7/0.5.8/0.5.10）
- 解决：`common.sh:55` 白名单追加版本（0.5.12/0.5.13 各自已加）

### 2.2 `Fatal: ... missing: ip, jq (common.sh:17)`
- 镜像缺工具（0.5.13 基础镜像缺，rc3 有）
- 解决：构建镜像时 `apt-get install -y --no-install-recommends iproute2 jq curl libcurl4`
  （厂商 common.sh:12 注释里就是这条命令）

### 2.3 `TypeError: Buffer.low_latency_dispatch() got an unexpected keyword argument 'topk_weights'`
- **根因**：deep_gemm 后端缺 `SGLANG_DEEPEP_BF16_DISPATCH=1` → use_fp8=True → 传库不支持的参数
- 解决：config.sh 加版本分支 `export SGLANG_DEEPEP_BF16_DISPATCH=1`（0.5.12 脚本自带）

### 2.4 `AssertionError: multi-node data parallel is not supported unless dp attention!`
- prefill dp>1 且 nnodes>1 但无 `--enable-dp-attention`（厂商 prefill.sh 原本 dp=1，无此处理）
- 解决：prefill.sh 补 `[ "$prefill_dp_size" -gt 1 ] && args+=(--enable-dp-attention)`

### 2.5 `ValueError: HiRadixCache only supports MHA, MLA, and NSA (DSA) models`
- DSv4 混合 attention 不被 HiRadixCache 支持
- 解决：**必须** `SGLANG_ENABLE_UNIFIED_RADIX_TREE=1`（走 UnifiedRadixCache）

### 2.6 `ValueError: deepseek_v4_c4_state state_pools must not contain None`
- PP>1 + hicache 装配器下标 bug（PP 各段只持有部分层）
- 解决：**r3 及以后镜像**（含 `patch_dsv4_hicache_pp.py`；r4 已含）

### 2.7 `'HybridAttnBackend' object has no attribute 'get_swa_out_cache_loc' / '_maybe_upgrade_forward_metadata'`
- 触发 A：有人给 prefill 加了 `--decode-attention-backend`（≠ 默认 dsv4）→ 包 HybridAttnBackend 且无转发
  → **删掉该参数**（r4 镜像的 prefill.sh 已含"不要加"的修复注释）
- 触发 B：**0.5.12 血统走 hicache** → hybrid backend 缺 dsv4 方法（引擎第二处代码缺口）
  → **0.5.12 走 hicache 不可行，必须 r4(0.5.13)**

### 2.8 `RuntimeError: shape '[4, 0, -1]' is invalid for input of size 4096`
- tp 不整除 o_groups=8（写死 pp 与节点数不匹配）→ `n_local_groups=0`
- 解决：`MY_PREFILL_PP_AUTO=1` 自适配；手动模式保证 pp ≥ nnodes 且 tp∈{1,2,4,8}

### 2.9 launcher 摘要打印一半、进程消失
- 根因：`set -euo pipefail` 下 `_show_var` 的 `val="$(grep ...)"` 在变量不存在时（如 0.5.12
  models 无 `context_length_specific`）直接杀死 launcher（**无任何错误输出**！）
- 解决：命令替换加 `|| true`（pd-launcher.sh 已修）

## 三、Mooncake / 存储类

### 3.1 `RPC call failed: invalid rpc arg` / `Failed to setup Mooncake store, error code: -900`
- **根因**：mooncake master 与 client 版本不匹配（跨引擎血统协议差异）
- 解决：**master 必须与 prefill client 同镜像版本**（r4 client → r4 master）

### 3.2 `Failed to connect to <ip> port 8080` / store error -600
- master 未启动 / 不在该 IP（先部署并验收 master：`ss -lntp | grep -E '50051|8080|9003'`）
- 排查链：master 的 metadata server（8080）是 hicache storage 注册的必需端点

### 3.3 `Failed to get fsdir from master`
- `MY_MOONCAKE_MASTER_SERVER_IP` 与 `MY_MOONCAKE_META_DATA_SERVER_IP` 与 master 实际
  落点不一致——**启动阶段不报错，只在 client 连接时暴露**
- 解决：两行**成对**改（leader 漂移后同步）

### 3.4 EPLB 未生效
- 变量名核对：0.5.12 脚本读 `decode_eplb_file_specific`（非 `decode_eplb_file`）
- models 文件**需有该变量的定义行**（launcher 的 `_override_var` 只 sed 已存在的行；
  原文件是注释行 → 需取消注释）
- 验证：argv 里有 `--enable-eplb --init-expert-location=<file>` + 日志 "EPLB is enabled"

## 四、崩溃 / 稳定性类

### 4.1 ⭐ `Xnack(0x8)` / `mcErrorIllegalAddress` 于 write_backup（L3 阻塞）
```
MXC: memory violation(0x4) → MCR: trapping kernel: transfer_kernel_impl
栈: _inc_hit_count → write_backup → move_hybrid_indices →
    cache_controller.py:780 host_indices.to(device)      ← 崩溃点
```
- **根因**：MACA transfer kernel 在 L3（mooncake client 注册）引入的 buffer/线程布局下
  触发竞态（同族症状见 GPUStack 文档 §4.6：`xnack_error + ATU invalid_xvm_pde`）
- **已排除**：拓扑形态、io-backend、env 缺失、权限、脚本差异、节点数——**L2-only 零崩溃证明崩溃仅由 L3 引入**
- **绕行（当前生产方案）**：**L2-only**（不设 `MY_TMUX_ENABLE_MOONCAKE_STORE`，用
  `MY_ENABLE_HICACHE=1`）——**L2 完整可用，45x 收益**
- **解锁**：① 向 GPUStack 索取 workaround 细节；② MACA 报障（证据链：MXC/MCR 日志 +
  Python 栈 + py-spy dump——**保留现场**）

### 4.2 负载下泛发 `illegal memory access`
- 检查 **MACA 用户态与驱动栈的匹配**（本集群：内核 3.9.6 / 用户态 3.8.2.6 / SDK 3.8.1.3）
- 3.7.x 用户态与 3.8.x 驱动混用 → graph 捕获/负载期崩（rc3 3.7.1.9 实例）
- 另有**单节点特例**：某节点先崩（曾经 node 33）→ 逐节点排除/OOM 核查（`dmesg`）

### 4.3 `CUDA_LAUNCH_BLOCKING=1` 不可用
- 现象：加后 hicache 初始化卡死（>25min 无 fired up）
- 结论：**该诊断手段在本栈不可用**，勿用于验证竞态假设（会引入新问题）

## 五、性能类

### 5.1 首轮压测数字偏低
- TileLang JIT 热身期（实测 470 → 1023 → 1238 tok/s 三轮爬升）
- 规范：**连续压测 2-3 轮取稳定值**

### 5.2 EAGLE/MTP 没开
- 0.5.12 血统读**环境变量** `decode_mtp_specific`（`decode_mtp_default="${decode_mtp_specific:-3}"`）
- launcher 回写 models 文件无效（文件里无定义行）→ **直接设 pod env**

### 5.3 max-running 与预期不符
- ⚠ **0.5.12 默认是 40（不是 8！）**：`decode_max_running_requests_default="${...:-40}"`
- 实测 160（40×dp4）最优；显式设 64 反而 -17%

### 5.4 压测数据集下载失败（离线环境）
- bench_serving 的 random/sharegpt 会下载 HF 文件
- 解决：本地 `--dataset-path /workspace/ShareGPT_V3_unfiltered_cleaned_split.json`
  （benchmark 镜像自带）；或 gsp 模式（`generated-shared-prefix`，本地生成）

## 六、部署 / 运维类

### 6.1 router 请求超时/挂死（/health 200 但请求超时，日志只有 Step failed）
- **router 后端必须填宿主机 IP**，**不能填 ClusterIP/VIP**（PD 工作流需真实可达地址）
- 获取：`kubectl get pods -l ... -o wide` 取 `*-0` pod 的 IP（hostNetwork = 节点 IP）

### 6.2 leader 漂移
- 整组重建后 worker-index=0 可能换节点 → **router 的两个 IP 需同步更新**
- 生效方式：改 router.yaml → apply → **`scale deploy --replicas=0` → 1**
  （hostNetwork 固定端口 8001，滚动更新会卡端口占用）

### 6.3 `kubectl apply -f` 部署"丢失"
- 单文件 apply **不带 namespace** → 落到 default namespace（kustomize 才有 namespace 字段）
- 解决：`kubectl -n metax-ai-pd apply -f xxx.yaml` 或走 `apply -k`

### 6.4 hostPath 日志混淆多实例
- `/var/log/sglang-*/` 日志**累积所有历史实例**——grep 尾部可能命中旧实例错误
- 甄别：按**时间戳**过滤（`grep "^\[2026-09-26 22:"`）或先 `date` 对时

---

## 附：GPUStack 环境特有坑（引自其部署手册）

| 症状 | 处置 |
|---|---|
| `DistStoreError: Timed out ... N clients joined` | 主 worker 重起多次端口漂移 → 删容器重启该 worker |
| UI 报 error 但容器在跑 | 3 秒健康同步误判（workload 未建出）→ 等自愈或 PUT 实例 state:"starting" |
| mooncake-master 一直 starting | 探针协议不匹配 → 版本已带存活端点 + `GPUSTACK_MODEL_HEALTH_CHECK_PATH=/` |
| master PENDING: requires ~334 GiB VRAM | 占位模型显存估算 → 版本已带 `GPUSTACK_MODEL_VRAM_CLAIM=1GiB`，节点需有空闲卡 |
| master 容器卡 Created | 落点节点缺引擎镜像 → 该节点 pull |
| 改 env/换镜像部署没变 | controller add-only + 内存缓存 → 刷 DB 键 → 重启 express/worker → 重 PUT |
