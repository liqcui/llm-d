#!/usr/bin/env bash
# 3P5D 部署脚本（pernode 变体：3×prefill + 5×decode）
# 前提：node36 标签切换为 decode（本脚本自动执行；幂等）
set -euo pipefail
METAX="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$METAX/deepseek-v4-flash-0731-pernode-3p5d"
echo "== 1/3 角色标签：prefill={28,29,31} decode={32,33,34,35,36} =="
for n in mxgpu-3-36; do  # 仅 36（3P5D：31 保持 prefill）
  kubectl label node $n metax-sglang-pd-prefill-dsv4-0731- metax-sglang-pd-decode-dsv4-0731=true --overwrite
done
echo "== 2/3 渲染（IP 占位符化） =="
python3 "$METAX/tools/render_site.py" "$DIR"
echo "== 3/3 apply =="
kubectl apply -k "$DIR/_rendered/lws/"
echo "== 完成：等 LWS 收敛（prefill 3 pod / decode 5 pod）+ boot（~10-15min） =="
echo "   就绪核验：prefill 1/1×3, decode 2/2×5; 真实 /generate 探测; router 3+5 列表"
