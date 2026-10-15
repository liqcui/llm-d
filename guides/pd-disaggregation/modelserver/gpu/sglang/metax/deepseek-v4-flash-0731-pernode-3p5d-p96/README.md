# deepseek-v4-flash-0731-pernode-3p5d — pernode 资源配比变体：3×prefill + 5×decode

**目的**：验证 decode 侧瓶颈假设——4+4 最优解基础上将 1 台节点从 prefill 转 decode。
**对照基线**：`deepseek-v4-flash-0731-pernode-best`（4+4，全场景零崩；见其 README 战绩）。
**角色分配**：prefill = node 29/31/28（3 台）；decode = node 35/34/33/32/36（5 台）。
**参数**：与 pernode-best 完全一致（每引擎 cap48/graph-bs 64/DSPARK6/mem 0.82+0.75），仅 replicas 3/5。

## 部署
```bash
bash deploy.sh   # 角色标签 + 渲染 + apply（幂等）
```
⚠ 拓扑切换后按既有铁律：等 LWS 自然滚动（勿滚动中强删 pod——会按组钉住旧 revision 重建）；
就绪判据=prefill 1/1×3 + decode 2/2×5 + 真实 /generate 200；router 端点=3+5 列表。

## 判定口径（10-15 深夜实验）
- 测格：std-c64 / std-c128 / std-c160（对照 4+4 同格：label final-2026-10-14-pernode / best-final-*）
- **若 5D 收益高 → 下一档 2P6D**（另一台转 decode）；若持平/劣 → 维持 4+4 最优解
- 每轮完成：push 代码 + 测试数据备份 MinIO（用户指令）

## 数据
label `ab-3p5d-*`；跑完入 DuckDB + MinIO `sglbench-backup-20261014/`。
