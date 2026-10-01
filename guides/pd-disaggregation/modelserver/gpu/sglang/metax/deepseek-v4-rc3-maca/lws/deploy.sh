#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════
# DeepSeek-V4 (rc3-maca) PD 分离 — 官方默认 / 最优解 一键部署
#
# 用法:
#   ./deploy.sh <official|optimal> [apply|delete]
#
# 变体 (两个独立 kustomize 目录, 只差 decode/prefill.yaml 的 env 值):
#   official  = 沐曦厂商官方默认参数 (tp32/dp32/ep32 + tp4/pp8, mem 0.80,
#               EAGLE=3, EPLB 关, max-running 40×dp)   → 298 tok/s 基准
#   optimal   = 2026-09-26 调参终版 (tp8/dp4/ep8 + tp8/dp4, mem 0.75/0.82,
#               EAGLE=5, EPLB 开, max-running 40×dp)   → 1238 tok/s 基准
#   详见 OPTIMIZATION.md。
#
# apply 之后脚本自动:
#   1. 等待 prefill/decode 两组 pod Ready (最长 15 分钟)
#   2. 读取两组 leader (worker-index=0) 的宿主机 IP
#   3. 若与 shared/router.yaml 中端点不一致, 自动 patch router 并重启
#      (hostNetwork 端口固定, 滚动更新需先 scale 0→1, 脚本代做)
#
# 前置: 节点标签已打 (prefill×4 / decode×4 / router×1), 模型在 8 节点
#       /data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8, LWS CRD 已装。
# ══════════════════════════════════════════════════════════════════════════
set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NS="${NS:-metax-ai-pd}"
ROUTER_DEPLOY="deepseek-v4-rc3-router"

VARIANT="${1:-}"
ACTION="${2:-apply}"
case "${VARIANT}" in
  official|optimal) ;;
  *) echo "用法: $0 <official|optimal> [apply|delete]" >&2; exit 1 ;;
esac
case "${ACTION}" in
  apply|delete) ;;
  *) echo "ACTION 必须为 apply 或 delete" >&2; exit 1 ;;
esac

VARIANT_DIR="${HERE}/${VARIANT}"
[ -f "${VARIANT_DIR}/kustomization.yaml" ] || { echo "[deploy] 缺少 ${VARIANT_DIR}/kustomization.yaml" >&2; exit 1; }

echo "[deploy] 变体=${VARIANT} 动作=${ACTION} 目录=${VARIANT_DIR}"
kubectl "${ACTION}" -k "${VARIANT_DIR}"

if [ "${ACTION}" = "delete" ]; then
  echo "[deploy] 完成: ${VARIANT} 已删除"
  exit 0
fi

# ── 等待 LWS 组就绪 ──
echo "[deploy] 等待 prefill/decode 两组 pod Ready (最长 15 分钟, 可 Ctrl-C 中断) ..."
kubectl -n "${NS}" wait --for=condition=Ready pod -l 'llm-d.ai/guide=pd-disaggregation,llm-d.ai/role=prefill' --timeout=900s 2>/dev/null || \
  echo "[deploy][WARN] prefill 组未在 15 分钟内全部 Ready, 请查看日志"
kubectl -n "${NS}" wait --for=condition=Ready pod -l 'llm-d.ai/guide=pd-disaggregation,llm-d.ai/role=decode' --timeout=900s 2>/dev/null || \
  echo "[deploy][WARN] decode 组未在 15 分钟内全部 Ready, 请查看日志"

# ── 同步 router 端点 (leader 漂移自动修复) ──
PREFILL_IP="$(kubectl -n "${NS}" get pod -l 'llm-d.ai/role=prefill,leaderworkerset.sigs.k8s.io/worker-index=0' -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
DECODE_IP="$(kubectl -n "${NS}" get pod -l 'llm-d.ai/role=decode,leaderworkerset.sigs.k8s.io/worker-index=0' -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"

if [ -n "${PREFILL_IP}" ] && [ -n "${DECODE_IP}" ]; then
  echo "[deploy] master 端点: prefill=${PREFILL_IP}:8000 decode=${DECODE_IP}:8200"
  PRE="$(kubectl -n "${NS}" get deploy "${ROUTER_DEPLOY}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PD_PREFILL_ENDPOINTS")].value}' 2>/dev/null || true)"
  DEC="$(kubectl -n "${NS}" get deploy "${ROUTER_DEPLOY}" -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="PD_DECODE_ENDPOINTS")].value}' 2>/dev/null || true)"
  if [ "${PRE}" = "${PREFILL_IP}:8000" ] && [ "${DEC}" = "${DECODE_IP}:8200" ]; then
    echo "[deploy] router 端点已是最新, 无需更新"
  else
    echo "[deploy] router 端点漂移 (${PRE:-<无>}/${DEC:-<无>}) → 更新并重启 (scale 0→1 绕开 hostNetwork 端口占用) ..."
    kubectl -n "${NS}" set env "deploy/${ROUTER_DEPLOY}" \
      "PD_PREFILL_ENDPOINTS=${PREFILL_IP}:8000" "PD_DECODE_ENDPOINTS=${DECODE_IP}:8200" >/dev/null
    kubectl -n "${NS}" scale "deploy/${ROUTER_DEPLOY}" --replicas=0 >/dev/null
    kubectl -n "${NS}" scale "deploy/${ROUTER_DEPLOY}" --replicas=1 >/dev/null
    kubectl -n "${NS}" rollout status "deploy/${ROUTER_DEPLOY}" --timeout=120s 2>/dev/null || true
  fi
else
  echo "[deploy][WARN] 未取到 master IP, 请手工核对 shared/router.yaml 端点"
fi

# ── 压测客户端 pod (benchmark 镜像; 每次部署后确保存在, 幂等) ──
BENCH_YAML="${HERE}/bench/bench-client.yaml"
if [ -f "${BENCH_YAML}" ]; then
  kubectl apply -f "${BENCH_YAML}" >/dev/null 2>&1 && \
    echo "[deploy] 压测客户端 pd-bench-client 就绪 (镜像 metax/sglang:benchmark, 见 bench/bench-client.yaml)"
else
  echo "[deploy][WARN] 缺少 ${BENCH_YAML}, 跳过压测客户端创建"
fi

echo
echo "[deploy] 完成: ${VARIANT}"
echo "  健康检查: curl -s http://${PREFILL_IP:-<ip>}:8000/health   (prefill)"
echo "            curl -s http://${DECODE_IP:-<ip>}:8200/health    (decode modelserver)"
echo "            curl -s http://${PREFILL_IP:-<ip>}:8998/route?prefill_dp_rank=-1&prefill_cp_rank=-1&target_tp_rank=-1&target_pp_rank=-1"
echo "  压测入口: http://<router 节点>:8001 (bench_serving 见 skill §1)"
