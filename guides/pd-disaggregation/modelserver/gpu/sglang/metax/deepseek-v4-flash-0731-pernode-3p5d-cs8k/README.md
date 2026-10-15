# deepseek-v4-flash-0731-pernode-3p5d-cs8k — 3P5D × chunked-prefill-size 8192（对照实验）

**目的**：在最优解环境（3P5D 冻结参数 + unified 镜像）标定 `chunked-prefill-size` 甜点。
**差异（仅此）**：`PD_CHUNKED_PREFILL_SIZE 16384 → 8192`（decode+prefill 双侧，保持配置对称；
decode 侧实际惰性、prefill 为主作用侧）；其余全同冻结档。
**对照基线（16384，冻结档既有数据）**：
- 65k-c1：10.02s / 5.37ms（ab-3p5d-lc65k-c1）
- 65k-c8：15.40s / 6.08ms（gap-3p5d-lc65k-c8）
- c128@r4：1.61s / 11.02ms（final-unified-c128-r4）

**判定**：label `cs8k-*`；长输入 TTFT/TPOT（65k 族）+ 混合负载（c128@r4）判别。
若 8192 有信号 → 续测 32768（另建目录或改本目录）。

## 运行
```bash
# render + apply（与 3p5d 同流程）
python3 ../tools/render_site.py .        # 或 bash deploy.sh（注意 deploy.sh 指向 3p5d，勿用）
kubectl apply -k _rendered/lws/
# 收敛核验 → 探测 → 测试（label cs8k-*）
```

## 状态
- 2026-10-15 17:0x 就绪（render 待跑）；测试链日志 /tmp/cs8k.log
