# deepseek-v4-flash-0731-pernode-3p5d-default — 3P5D × 官方默认参数（对照实验）

**目的**：3P5D 拓扑下 **厂商标定参数（撤全部对齐项）** vs **我们对齐参数**（3p5d 目录）的公平对照。
**差异（仅此）**：无 max-running / graph-bs / mem-frac / chunked 对齐覆盖 → 由厂商脚本/引擎默认接管。
**其余全同**：3P+5D 拓扑、explicit 启动、DSPARK6、镜像、router 3+5。**deploy.sh 保留启动参数**。
**判定**：同网格对照（c64/c128/c160 + 边界档）label `ab-3p5d-default-*`。

## 运行状态：已备未跑（10-15 07:15 时间盒判定）
- 变体资产齐备（渲染 ✓ / deploy.sh ✓ / 启动参数保留）；因 08:30 数据停线约束，本轮未部署
- **后续运行步骤**：`bash deploy.sh`（3+5 标签态）→ 等 rolling 收敛（~30min，组间滚动）→
  同网格对照：`--label ab-3p5d-default-{c64-r2,c128-r4,c160-r5}`（对照 3p5d 目录 data）
- 预期看点：无 cap48 约束下的吞吐上限 vs 池压力风险；无 graph-bs 64 时 DSPARK bs 重建路径
