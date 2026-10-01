# MetaX C500 DeepSeek-V4 PD 分离 — 场景化最佳实践总表（2026-09-26 终版）

> 所有数据来自本集群实测（8 节点 × 8 卡 C500；MACA 内核 3.9.6 / 用户态 3.8.2.6 /
> SDK 3.8.1.3）。压测：benchmark 镜像 + ShareGPT/本地数据集。

---

## 一、总览矩阵：场景 → 最佳镜像 → 最佳配置 → 实测性能

| # | 场景 | 最佳镜像 | 核心配置 | 状态 | **实测性能** |
|---|---|---|---|---|---|
| **A** | **生产推理**（PD 分离，通用）| `0.5.12-maca.ai3.8.2.7-torch2.10-py312-ubuntu22.04-amd64-llm` | official 模式；P: tp8/dp4/pp1；D: tp8/ep8/dp4/pp1；mem 0.75(d)；EAGLE draft=5；EPLB；max-running 厂商默认 | ✅ **生产就绪** | **1238 tok/s**（512/128, 100req）；TTFT 0.82s；TPOT 36.8ms；长上下文 4096/2048 达 **1481 tok/s** |
| **B** | **HiCache L2**（长 SystemPrompt / 多轮对话 KV 复用）| `0.5.13-dsv4-adapter-r4-hicache-l2`（prefill）+ A 的镜像（decode）| P: `MY_ENABLE_HICACHE=1`（**L2-only，无 mooncake**）+ `SGLANG_ENABLE_UNIFIED_RADIX_TREE=1` + tp8/pp4(auto)；D: 同 A | ✅ **今晚验证通过** | **同 prompt 两连发：58.55s → 1.30s（45x）**；命中 1280/1359 token；**host 池容量 ~484 万 token**；零崩溃 |
| C | HiCache L3（Mooncake 跨实例 KV Store）| `0.5.13-dsv4-adapter-r4-hicache` + mooncake master(r4) | B + `MY_TMUX_ENABLE_MOONCAKE_STORE=1` + master IP | ❌ **阻塞**（MACA transfer kernel 竞态）| 功能链路曾验证（prefetch loaded=512）；write 路径崩溃，根因定位见 §四 |
| D | 单机 prefill（8 卡）| 同 A/B | **PP8/TP1/DP1**（厂商验证形态）| ✅ 可用 | — |
| E | 0.5.12 系走 HiCache | — | — | ❌ **不可行**（引擎代码缺口 ×2：L3 方法缺失 + HybridAttnBackend 方法缺失）| — |

## 二、场景 A：生产 PD 分离（详细配置）

**部署**：`deepseek-v4-rc3-maca/lws/`（4 节点 prefill + 4 节点 decode + router）

| 项 | prefill | decode |
|---|---|---|
| 镜像 | `0.5.12-maca.ai3.8.2.7-...-llm` | 同 |
| 启动模式 | official（厂商 llm-launch）| 同 |
| 拓扑 | tp=8 / dp=4 / pp=1 | tp=8 / ep=8 / dp=4 / pp=1 |
| mem-fraction | 0.82（厂商）| **0.75**（压测标定）|
| 并发 | 厂商默认（64×dp4=256）| 厂商默认（40×dp4=160）|
| 投机解码 | — | **EAGLE draft=5**（`decode_mtp_specific=5`）|
| EPLB | — | 开（`--enable-eplb` + 预计算文件）|
| chunked-prefill | 4096（×dp4=16384）| — |
| Router | 后端**填宿主机 IP**（leader 漂移后同步）| — |

**调优结论速查**：mem 0.72→0.75 (+50%)；draft 3→5 最优（6 变差）；max-running 64 反而
-17%（160 最优）；chunked 8192 负优化；graph-max-bs 自动 160。

## 三、场景 B：HiCache L2（本次重大成果）

**部署**：`deepseek-hicache/`（prefill LWS `prefill-hicache` + 生产 decode 复用）

**prefill 关键配置**（env）：
```
MY_ENABLE_HICACHE=1                      # ★ L2 开关 (config.sh 环境化补丁; r4 原生 hard-false)
SGLANG_ENABLE_UNIFIED_RADIX_TREE=1       # DSv4 必须
# 不设 MY_TMUX_ENABLE_MOONCAKE_STORE     # ← L2-only: 不加 --hicache-storage-backend
拓扑: tp8/pp4/dp1 (MY_PREFILL_PP_AUTO=1 / 4 节点)
其余对齐 GPUStack 全套 MACA/框架 env (privileged / shm 100Gi / memlock 均核对无缺)
```

**实测收益（1359-token prompt 两连发）**：

| 指标 | 请求 1（冷）| 请求 2（命中）| 收益 |
|---|---|---|---|
| **总耗时** | 58.55s | **1.30s** | **45 倍** |
| cached-token | 0 | **1280** | — |
| `hicache_host_used_tokens` | — | **1280**（与命中精确吻合）| 写回→命中闭环证据 |
| host 池容量 | — | **~484 万 token** | 巨大复用空间 |

**业务流量验证（2026-09-26 晚，长 SystemPrompt 场景）**：

| 测试 | 结果 |
|---|---|
| 固定 1684-token SystemPrompt + 15 个不同问题 | 冷 1.12s → 命中均值 **0.63s**（TTFT **-57%**；命中后仅剩链路底噪 ~0.48s）|
| **稳定性测试**：50 混合请求（20 × SystemPrompt 命中 + 20 × 512~3000 token 压力 + 10 × 长程回访）| **0 失败**，全程 32s；段1均值 0.51s / 段2压力 0.83s / **段3 长程命中 0.48s**（经压力冲击后原 SystemPrompt 仍命中）；**全程零崩溃** |
| L2 池增长 | 1280 → 2816 → 4608 token（持续写回正常）|

**收益规律**：SystemPrompt 越长、环境越冷，命中收益越大（消掉全部 prefill 计算时间，
只剩 router+decode+握手底噪 ~0.48s）。**收益场景**：长 SystemPrompt 复用（多请求共享同一前缀）、多轮对话（同会话后续轮次）
- **代价**：冷启动 ~15 分钟（TileLang JIT，属正常）；host DRAM 占用（hicache-ratio 2 × GPU 池）；首次请求不命中
- **判据**：若业务中"相同/相似长前缀"的请求占比高 → 必开；纯随机独特 prompt → 收益有限

## 四、场景 C：HiCache L3 阻塞说明（待解锁）

- **现象**：启用 mooncake 后，请求完成时 `_inc_hit_count → write_backup →
  host_indices.to(device)` 触发 MACA `transfer_kernel_impl` Xnack(0x8)/
  mcErrorIllegalAddress → scheduler 崩
- **已排除**：拓扑形态（单机 PP8/TP1 同样崩）、io-backend（direct/kernel）、
  env 缺失（对齐后仍崩）、权限（privileged/shm/memlock ✓）、脚本差异（行为等价）、
  节点数、L2 路径本身（**L2-only 零崩溃证明**）
- **精确结论**：**崩溃仅由 L3（mooncake client 注册）引入**——L2 写回/装配/一切本地路径正常
- **解锁路径**：① 向 GPUStack 索取 "compatibility workaround" 具体内容（同服务器同驱动
  他们 L3 跑通）；② MACA 报障（证据链完整：MXC/MCR 日志 + Python 栈 + py-spy dump）

## 五、镜像清单（唯一交付版本）

| 镜像 tag | digest 前缀 | 用途 |
|---|---|---|
| `0.5.12-maca.ai3.8.2.7-...-llm` | `00ea987d` | **场景 A 生产**（含全部脚本补丁）|
| `0.5.13-dsv4-adapter-r4-hicache-l2` | `549d47b2` | **场景 B L2-only**（r4 + L2 环境化补丁）|
| `0.5.13-dsv4-adapter-r4-hicache` | `2b482c62` | 场景 C L3（阻塞中）|
| `0.5.13-dsv4-adapter-r4` | `10b8120e` | 底座（GPUStack 原版）|
| `v0.5.12-glm5-rc4-pd` | — | **router 专用**（模型镜像的 router 无 GPU 会崩 CUDA init）|
| `0.5.12-maca...-llm-hicache-l2-r2` | `01267e37` | 0.5.12 L2 实验（已证不可行，存档）|

## 六、当前集群运行态（= 场景 A 基础上 prefill 切 B）

```
decode-dsv4rc3 ×4 (0.5.12-llm) ──┐
                                 ├─→ router → 端到端 ✅
prefill-hicache ×4 (r4-hicache-l2, L2-only) ─┘
```
即 **"PD 分离 + HiCache L2"** 组合已在线运行（上述 45x 数据即经此链路实测）。

## 七、关键提醒

1. **router 后端必须填宿主机 IP**；leader 漂移后同步（当前 P=10.66.3.28 / D=10.66.3.34）；
   router 用 `-pd` 专用镜像；hostNetwork 端口占用时 scale 0→1 切换
2. **冷启动 15 分钟属正常**（TileLang JIT），探针未过勿误判
3. **重建镜像后若节点拉到旧 digest** → 换新 tag（本集群 containerd 已验证行为）
4. `kubectl apply -f` 单文件**不带 namespace**（用 `-n metax-ai-pd` 或走 kustomization）
