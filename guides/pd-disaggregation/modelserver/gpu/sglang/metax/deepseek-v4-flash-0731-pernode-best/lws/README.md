# DeepSeek-V4-Flash-0731 — PD 分离部署方案（0.5.14, pp1 最优拓扑）

> 参照 `deepseek-v4-rc3-maca/lws/` 的**生产最优解拓扑**（tp8/pp1/dp4，4.1x 吞吐 vs 厂商默认），
> 换 0.5.14 新镜像 + **非官方脚本直启**（用户给定 0.5.14 验证参数，含 DSPARK 投机解码）。

**验收状态**：✅ 已部署验证（8/8 ready + E2E 正确 + battery 6/6 全绿 + max-running 调优标定 40）。
**2026-10-08 晚 decode retract 崩溃修复**：0.5.14 官方镜像在 max-running=40 下触发
retract→offload→混合 SWA 池 `NotImplementedError` 整组崩溃（与 0.5.12 同款双缺陷）→ 最小补丁镜像
`0.5.14-maca.ai3.8.2.122-dsv4-0731-retractfix`（`image/{apply_retract_fix.py,Dockerfile.retractfix}`，
2 文件 3 处：retract 优雅降级 + offload gate + func_timer dedup）。**修复后 conc-64@40：
1901.5 tok/s（2.88x vs 10 档）、200/200 零崩溃**。完整数据见 sglbench 报告
`docs/TEST-REPORT-2026-10-08-dsv4-0731-first-battery.md`。单机 207 tok/s@8并发 (DSPARK accept 0.18)，
PD 150.6 tok/s@8并发。`image/` 下 modelslim 旧补丁仅适用于旧格式模型，保留备查

**2026-10-09 凌晨 HiCache L2（prefill-only）接入**：launcher 新增 `PD_ENABLE_HICACHE` 开关
（=1 时注入 hicache flag + 自动伴生 `SGLANG_ENABLE_UNIFIED_RADIX_TREE=1`——DSv4 混合
attention 必需）；标定组合 ratio 0.5 / page_first / direct（引擎改写为 page_first_direct）。
测试结论：随机 prompt 无效应（±噪声）；**多轮复用场景稳态温和收益（~10-30%）**；建议按业务
场景切换（单 env + prefill 单次滚动 ~6min）。详见 sglbench 报告
`docs/TEST-REPORT-2026-10-08-hicache-l2-0731.md`（含测量学修正：早期轮次尖峰为 JIT/热身伪影，
非 L2 效应）

---

## 1. 方案概览

| 项 | 值 |
|----|----|
| 模型 | `DeepSeek-V4-Flash-0731-W8A8`（**2026-10-08 沐曦适配版 LLMC SmoothQuant W8A8**，`/data/DeepSeek-V4-Flash-0731-W8A8`；官方镜像原生支持，零补丁） |
| 镜像 | prefill: `harbor.isuanova.com/metax/sglang:0.5.14-maca.ai3.8.2.122-torch2.10-py312-ubuntu22.04-amd64`（官方原版）；decode: `0.5.14-maca.ai3.8.2.122-dsv4-0731-retractfix`（retract 崩溃最小补丁，digest `fb9cff47`） |
| 拓扑 | **4 Prefill + 4 Decode（1 个逻辑实例）**：LWS `replicas=1, size=4`（4 节点 × 8 卡 = 32 卡/角色） |
| Prefill | TP=8 PP=1 DP=4（`--tp 8`，sglang 推导 dp=world/tp=4；launcher 显式传 `--dp-size 4 --enable-dp-attention`） |
| Decode | TP=8 DP=4 EP=8，**DSPARK 投机解码**（`--speculative-algorithm DSPARK --speculative-dspark-block-size 6`） |
| 启动 | **explicit（非官方脚本）**：pd-launcher.sh 直启 `python3 -m sglang.launch_server`，参数 1:1 对齐用户给定 |
| 网关 | **llm-d EPP**（InferencePool 发现）+ **deepseek-v4-0731-router**（sglang_router，压测入口，sglbench DeepSeek 场景默认指向） |

## 2. 启动参数（用户给定，env 可覆盖）

```bash
python3 -m sglang.launch_server \
  --model-path /workspace/data/DeepSeek-V4-Flash-0731-w8a8/ \
  --tp 8 --trust-remote-code \
  --context-length 400000 --max-running-requests 10 \
  --port 8000 --host 0.0.0.0 \
  --tool-call-parser deepseekv4 --reasoning-parser deepseek-v4 --served-model-name DeepSeek-V4-Flash \
  --speculative-algorithm DSPARK --speculative-dspark-block-size 6 \
  --chunked-prefill-size 16384 --page-size 64 --kv-cache-dtype bfloat16 \
  --schedule-conservativeness 0.6
```

env（pod 注入，两角色共用）：

```bash
export PYTORCH_ENABLE_PG_HIGH_PRIORITY_STREAM=1
export MACA_SMALL_PAGESIZE_ENABLE=1
export CUDA_GRAPH_DP_USE_SUM_BS=False
export SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1
export SGLANG_DSPARK_KERNEL_COMMIT_KV_PROJ=torch
```

**launcher 追加的角色/PD 参数**（不在用户命令里、PD 必需）：
- 两角色：`--nnodes 4 --node-rank N --dist-init-addr <master>:5000 --disaggregation-mode <role> --disaggregation-ib-device mlx5_0 --disaggregation-bootstrap-port 8998 --dist-timeout 300 --mem-fraction-static <role默认> --enable-metrics`；dp>1 → `--dp-size 4 --enable-dp-attention --enable-dp-lm-head`
- prefill：`--port 8000`，mem 0.82（rc3 标定）
- decode：`--port 8200`，mem 0.75（rc3 标定），`--speculative-algorithm DSPARK --speculative-dspark-block-size 6 --cuda-graph-max-bs 8`

> ⚠ mem-fraction 不在用户命令里；按 rc3 实测标定补了 prefill 0.82 / decode 0.75
> （厂商查表无此 GPU 档位 + graph 捕获余量约束）。如 0.5.14 有更好标定值，用 `PD_MEM_FRACTION_STATIC` 覆盖。

## 3. 目录结构

```
deepseek-v4-flash-0731-pp1/lws/
├── kustomization.yaml   # 部署入口 (namespace: metax-ai-pd)
└── base/
    ├── prefill.yaml     # LWS prefill-dsv4-0731: replicas=1 size=4, :8000 + bootstrap :8998
    ├── decode.yaml      # LWS decode-dsv4-0731: modelserver :8200 + routing-proxy sidecar :8000
    ├── router.yaml      # deepseek-v4-0731-router (sglang_router, :8001, env 驱动端点)
    ├── services.yaml    # prefill/decode headless (EPP 发现)
    ├── serviceAccount.yaml
    ├── rbac.yaml        # pod-reader (launcher 查 leader 真实 host IP)
    └── launcher-configmap.yaml  # pd-launcher-dsv4-0731 (直启启动器, 用户参数)
```

## 4. 部署

```bash
# 0) 前置: LWS CRD、InferencePool/EPP 已装; 模型已分发 (/data/DeepSeek-V4-Flash-0731-w8a8)
# 1) 节点标签 (与 GLM/rc3 同节点互斥; 先删旧 PD 集群)
kubectl label node mxgpu-3-28 mxgpu-3-29 mxgpu-3-31 mxgpu-3-36 \
    metax-sglang-pd-prefill-dsv4-0731=true --overwrite
kubectl label node mxgpu-3-32 mxgpu-3-33 mxgpu-3-34 mxgpu-3-35 \
    metax-sglang-pd-decode-dsv4-0731=true --overwrite
kubectl label node mxgpu-3-32 metax-sglang-pd-router-dsv4-0731=true --overwrite
# 2) 部署
kubectl apply -k guides/pd-disaggregation/modelserver/gpu/sglang/metax/deepseek-v4-flash-0731-pp1/lws/
# 3) 更新 router master IP (prefill/decode-dsv4-0731-0 实际落点) → kubectl set env / edit + rollout restart
kubectl -n metax-ai-pd get pods -o wide | grep dsv4-0731
```

## 5. 可调参数（pd-launcher env）

| env | 作用 | 默认 |
|-----|------|------|
| `PD_MODEL_PATH` | 模型路径 | /workspace/data/DeepSeek-V4-Flash-0731-w8a8 |
| `PD_TP_SIZE` / `PD_DP_SIZE` | 张量/数据并行 | 8 / 4 |
| `PD_CONTEXT_LENGTH` | 上下文长度 | 400000 |
| `PD_MAX_RUNNING_REQUESTS` | 最大运行请求 | 40（10-08 标定：conc-64 660→1901 tok/s；80 回退 -18.9%） |
| `PD_CUDA_GRAPH_MAX_BS` | decode CUDA graph 上限（引擎内部压回 ≤10） | 40 |
| `PD_ENABLE_HICACHE` | prefill HiCache L2 开关（伴生 unified radix tree 自动注入） | 0（多轮复用场景可设 1） |
| `PD_HICACHE_RATIO` / `PD_HICACHE_MEM_LAYOUT` / `PD_HICACHE_IO_BACKEND` | L2 标定组合 | 0.5 / page_first / direct |
| `PD_CHUNKED_PREFILL_SIZE` | prefill 分块 | 16384 |
| `PD_PAGE_SIZE` | KV 页大小 | 64 |
| `PD_KV_CACHE_DTYPE` | KV 缓存精度 | bfloat16 |
| `PD_SCHEDULE_CONSERVATIVENESS` | 调度保守度 | 0.6 |
| `PD_DSPARK_BLOCK_SIZE` | DSPARK 块大小 (decode) | 6 |
| `PD_MEM_FRACTION_STATIC` | KV 池显存占比 | prefill 0.82 / decode 0.75 |
| `PD_DISAGG_IB_DEVICE` | PD IB 设备 | mlx5_0 |
| `PD_MASTER_IP` | 显式 master（一般留空自动解析） | 空 |
| `PD_EXTRA_ARGS` | 自由追加 argv | 空 |
| `PD_DRY_RUN` | 只打印不启动 | 空 |

## 6. 验收清单

```bash
# 1) Pod 就绪: prefill 4×1/1, decode 4×2/2
kubectl -n metax-ai-pd get pods -l 'llm-d.ai/guide=pd-disaggregation'
# 2) P/D health = 200
curl -s -o /dev/null -w "%{http_code}\n" http://<prefill-ip>:8000/health
curl -s -o /dev/null -w "%{http_code}\n" http://<decode-ip>:8200/health
# 3) PD bootstrap 8998
curl -s -o /dev/null -w "%{http_code}\n" "http://<prefill-ip>:8998/route?prefill_dp_rank=-1&prefill_cp_rank=-1&target_tp_rank=-1&target_pp_rank=-1"
# 4) metrics
curl -s http://<prefill-ip>:8000/metrics | grep -v '^#' | wc -l
# 5) 端到端 (router)
curl -s --max-time 120 -X POST http://{{IP_DECODE_3}}:8001/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"DeepSeek-V4-Flash","messages":[{"role":"user","content":"请只回复 OK"}],"max_tokens":16,"temperature":0}'
```

## 7. 排障

| 现象 | 处理 |
|------|------|
| 启动报 `unrecognized arguments` / `invalid choice` | 0.5.14 参数名与 rc3 不同 → 检查 launch 日志, 用 `PD_EXTRA_ARGS`/注释对应参数; 若镜像缺补丁 → **基于 0.5.14 重打新镜像** |
| decode DSPARK 报错 | `SGLANG_DSPARK_KERNEL_COMMIT_KV_PROJ=torch` 已注入; 确认镜像含 DSPARK 支持 (0.5.14 应内置) |
| leader 漂移后 router 502 | 更新 router env master IP → `kubectl rollout restart deploy/deepseek-v4-0731-router` |
| 与 GLM/rc3 并存冲突 | hostNetwork 端口互斥, 同节点不可并存; 节点标签按角色互斥 |
| 崩溃后整组重建卡 Terminating | 强制删卡死 pod (`kubectl delete pod <name> --force --grace-period=0`) |
| PD KV 传输 `mcIpcOpenMemHandle mcErrorInvalidDevicePointer` | 缺 `MC_MACA_HOST_TRANSPORT=1`（rc4 镜像 config.sh 自带），已在 prefill/decode env 补齐 |
| router `all circuits open or unhealthy` 且后端健康 | router 熔断在失败请求后不自动闭合 → 重启 router pod |
| DSPARK `gamma mismatch: gamma=6 but draft block_size=5` | 警告级；block_size 6 → num_draft_tokens 7 → gamma 6，按用户给定参数保留 |
| `wqkv_a.weight_offset` not initialized 告警 | offset 全零 (实测 max|.|=0) 且 mctlass 路径不用, 无害 |
