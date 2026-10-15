# deepseek-v4-flash-0731-pernode-3p5d-cap56 — 参数扫描 B1: decode max-running 48→56

**目的**：3P5D decode 侧（5 引擎）cap 上探——容量×5 引擎后单引擎 cap 提高是否增益高并发格。
**差异（仅此）**：decode `PD_MAX_RUNNING_REQUESTS 48→56`（< graph-bs 64 约束保持 ✓）；其余全同冻结档。
**对照基线（16384/48，冻结档）**：c64@r3 1.19s/9.97ms · c128@r4 1.61s/11.02ms ·
c160@r5 2.35s/12.32ms（rep2）· c192@r5 2.56s/12.70ms（rep2）。
**判定**：label `cap56-*`；≥2 格超噪声带改善才采纳。
