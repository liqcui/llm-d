# deepseek-v4-flash-0731-official-pp4 — PP4 对比战役（official 官方脚本模式）

**目的**：官方 0.5.14 镜像 + llm-launch 官方脚本，在**厂商推荐默认拓扑（prefill PP4/tp8/dp1）**下
与当前 PP1 最优解（`deepseek-v4-flash-0731-pp1`，explicit 模式）做全面性能比较。

## 配置要点

| 项 | 值 |
|---|---|
| 镜像 | `…:0.5.14-maca.ai3.8.2.122-dsv4-0731-llm-retractfix`（官方脚本适配 + retract 修复，digest 46db2551） |
| 启动模式 | `PD_LAUNCH_MODE=official`（pd-launcher 双模式 → exec 镜像内 `/workspace/llm-launch/sglang/{prefill,decode}.sh`） |
| prefill 拓扑 | **pp4 / tp8 / dp1**（厂商默认；tp = 32/pp） |
| decode 拓扑 | pp1 / tp8 / dp4 / ep1 + DSPARK block 6（与 PP1 侧引擎参数对齐） |
| 并发 | decode `16`×dp4=64；prefill pre_batch 64（对齐 PP1 cap64） |
| L2 | off（`MY_ENABLE_HICACHE=0`） |
| 模型 | `/workspace/data/DeepSeek-V4-Flash-0731-W8A8`（LLMC，经 launcher 回写 model_path_specific） |

## 部署 / 互切

```bash
# 切到 PP4（就地滚动; 资源名与 pp1 目录相同）
kubectl apply -k deepseek-v4-flash-0731-official-pp4/lws/
# 切回 PP1
kubectl apply -k deepseek-v4-flash-0731-pp1/lws/   # 再补 cap64/L2 等 live 态
```

## 关键移植点（详见 TEST-REPORT，战役后补）

1. 0731 launcher 原为 explicit-only → 本目录换用 **r4-hicache 双模式 launcher**（env→厂商脚本变量回写）。
2. 0731 模型 spec（镜像内）model 路径为旧 modelslim 目录 → 由 `PD_MODEL_PATH` 回写修正。
3. prefill `prefill_pp_size_default` 双变量回写（0.5.13 血统坑）；dp>1 时自动注入 dp-attention。
4. decode max-running 厂商语义 = 每 DP rank（×dp 为总并发）。
