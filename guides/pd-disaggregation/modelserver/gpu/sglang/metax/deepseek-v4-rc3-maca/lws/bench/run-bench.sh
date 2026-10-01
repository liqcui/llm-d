#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# 标准压测 — 在 pd-bench-client pod 内跑 bench_serving (经 sglang router)
#
# 用法:
#   ./run-bench.sh                        # 标准: 512ctx/128out, 100 req, rate 20
#   ./run-bench.sh 512 128 100 20         # 自定义: ctx out num-prompts rate
#   ROUTER_IP=10.66.3.32 ./run-bench.sh   # 指定 router 地址 (默认自动探测)
#
# ⚠ 首轮压测偏低是 TileLang JIT 热身 → 连续跑 2-3 轮取稳定值。
# ⚠ 数据集必须用本地 --dataset-path (镜像内置 ShareGPT), 离线环境不能下载。
# ══════════════════════════════════════════════════════════════════════════
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-metax-ai-pd}"
CTX="${1:-512}"
OUT="${2:-128}"
NPROMPTS="${3:-100}"
RATE="${4:-20}"

# 自动探测 router IP (hostNetwork pod, 取节点 IP)
if [ -z "${ROUTER_IP:-}" ]; then
  ROUTER_IP="$(kubectl -n "${NS}" get pod -l 'app=deepseek-v4-rc3-router' -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
fi
[ -n "${ROUTER_IP}" ] || { echo "[bench] 未找到 router pod, 请用 ROUTER_IP= 指定" >&2; exit 1; }

kubectl -n "${NS}" get pod pd-bench-client >/dev/null 2>&1 || {
  echo "[bench] pd-bench-client 不存在, 先创建: kubectl apply -f ${HERE}/bench-client.yaml" >&2; exit 1
}

echo "[bench] router=${ROUTER_IP}:8001  ctx=${CTX} out=${OUT} prompts=${NPROMPTS} rate=${RATE}"
kubectl -n "${NS}" exec pd-bench-client -- bash -c "
  /opt/conda/bin/python3 -m sglang.bench_serving --backend sglang \
    --base-url http://${ROUTER_IP}:8001 \
    --model /workspace/data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8 \
    --tokenizer /workspace/data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8 \
    --dataset-name sharegpt \
    --dataset-path /workspace/ShareGPT_V3_unfiltered_cleaned_split.json \
    --sharegpt-context-len ${CTX} --sharegpt-output-len ${OUT} \
    --num-prompts ${NPROMPTS} --request-rate ${RATE}"
