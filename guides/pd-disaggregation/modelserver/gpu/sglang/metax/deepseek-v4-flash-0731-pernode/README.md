# deepseek-v4-flash-0731-pernode — "每节点独立引擎" PD 形态

**动机**：单机探测（10-12）证实 **节点内 tp8（8 卡）** 单流 ~210-226 tok/s / ITL 4.5ms / TTFT 0.22s
——是当前跨节点 tp8（每节点 2 卡）PD 形态（单流 104 tok/s / ITL 9.3ms）的 2.2x。
本目录 = 把 PD 重构为 **4+4 台单节点独立 tp8 引擎**（LWS replicas=4 / size=1），
prefill↔decode 配对由 router 逐请求完成（端点列表见 router.yaml）。

## 拓扑
| 侧 | 形态 | 说明 |
|---|---|---|
| prefill ×4 | 每节点 1 台 tp8/dp1/pp1 引擎 (node 29/31/36/28) | explicit 直启 (launcher NNODES=1 自动) |
| decode ×4 | 每节点 1 台 tp8/dp1/pp1 + DSPARK6 (node 35/34/33/32) | max-running 64/引擎 |
| router | 端点各 4 项, 逐请求 PD 配对 | hostNetwork :8001 (node 32) |

## 关键差异 vs pp1 目录
- `replicas: 4` + `size: 1`（原 1/4 单一大引擎）
- `PD_DP_SIZE=1`（引擎内无 DP；4 引擎在 router 层承担 DP 角色）
- router 端点 = 4+4 节点列表；KV 传输/引导端口各引擎自足

## 部署 / 互切
```bash
kubectl apply -k deepseek-v4-flash-0731-pernode/lws/
# 与 pp1 目录同名资源互斥；切回: kubectl apply -k deepseek-v4-flash-0731-pp1/lws/ (+cap64 patch)
```

## 预期与已知权衡（10-12 单机探测外推）
- 单流 ~200+ tok/s / TTFT ~0.2-0.5s（节点内 tp8 收益）
- 高并发聚合 ≥ 4×单机（prefill/decode 分工限制待实测）
- ⚠ 长上下文（65K）prefill 无 PP 流水线 → 单流 65K TTFT 预计 ~17s（单机实测值），
  劣于 pp4 的 5.3s —— 长上下文场景需对照后取舍

---

## 终版标定（2026-10-12 晚，P1-P4 战役收官）

| 参数 | 终版值 | 依据 |
|---|---|---|
| 每引擎 `PD_MAX_RUNNING_REQUESTS` | **48**（×4 = 192 总） | cap16→并发 TTFT 崩；cap32→conc64 略优但 160 无余量；**cap48 = 160 并发零失败 TTFT 2.0s / 峰值 3354 tok/s** |
| `PD_CUDA_GRAPH_MAX_BS` | **64**（必须 > max-running） | 引擎 `_recompute` 仅在 adjusted≠requested 时重建 bs 列表；dp1 下只有 graph-bs>cap 才能触发（否则 DSPARK NoneType 崩，cap160 同根因） |
| `PD_ENABLE_DSPARK` | **1**（保留） | A/B 实测：单流 TPOT 5.5 vs 16.6ms（3x）、吞吐 2.5x、b128 TTFT 5.9x |

**终版战绩**（vs 老跨节点 PD）：吞吐峰值 **+54%**（3354 vs 2179）；TTFT 并行场景 2-9x
（conc160: 2.0s vs 13.4s）；单流 TPOT 5.5ms vs 9.3ms（1.7x）。
**已知缺点**：65K 级长单流 prefill 无 PP 流水线（13.0s vs pp4 的 5.3s）；
8 引擎运维面 ×2；per-engine 参数语义需记 graph-bs>cap 规则。
详见 `sglang-benchmark-tools/docs/TEST-REPORT-2026-10-10-0731-comprehensive.md` §9。

> 完整部署与运维手册见 `DEPLOY.md`；最优参数解见 `OPTIMIZATION.md`。
