#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# run_full8_comparison.sh — "全量 8 卡/节点" PD 形态公平对照战役编排
#
# 名册（全部形态落实 8 卡/节点）:
#   pernode  = router 层 DP, 4×8卡引擎（参照, 已有全量数据）
#   f4       = full4p4d = "pp1-explicit 全量版"（tp32 单引擎, 引擎内 DP）
#   pp4      = pp4-official（全量; ⚠ 其"2卡"为推断, 本脚本启动后核验实际足迹）
#
# 每形态流程: render(IP 注入) → apply 切换 → leader 同步(漂移自愈) → wait_ready
#             → 足迹核验(8 proc/节点?) → graph 档核验 → [可选电池]
#
# 前置:
#   1) 各目录 site-config.env 已拷贝填写（真实 IP, 不入库）——pp4 目录亦同
#   2) sglbench 工具已更新且可在 ~/sglang-benchmark-tools 运行（本脚本仅用其稳定 CLI:
#      `python3 -m sglbench run` / `multiturn`，env 快照 envs/dsv4-0731-*.json）
#   3) 集群 8 节点空闲（形态互斥; 脚本末段自动恢复 pernode）
#
# 用法:
#   bash run_full8_comparison.sh footprint [form]   # 部署+足迹核验(不压测)
#   bash run_full8_comparison.sh test <form>        # 某形态完整电池(切换+就绪+压测)
#   bash run_full8_comparison.sh all                # 全流程(pernode 参照跳过压测→f4→pp4)→恢复 pernode
#
# 铁律内置: leader 漂移自愈 / roll 后 warmup / 每格失败恢复重试 / 全程 sglbench 落 DuckDB
# ═══════════════════════════════════════════════════════════════════════════
set -u
METAX=/home/supperadm/llm-d/guides/pd-disaggregation/modelserver/gpu/sglang/metax
SGLB=$HOME/sglang-benchmark-tools
NS=metax-ai-pd
log(){ echo "$(date +%F_%H:%M:%S) $*"; }
die(){ log "❌ $*"; exit 1; }

form_dir() { case "$1" in
  pernode) echo "$METAX/deepseek-v4-flash-0731-pernode";;
  f4)      echo "$METAX/deepseek-v4-flash-0731-full4p4d";;
  pp4)     echo "$METAX/deepseek-v4-flash-0731-official-pp4";;
  *) die "未知形态: $1 (pernode|f4|pp4)";;
esac; }
form_env() { case "$1" in
  pernode) echo "dsv4-0731-pernode";;
  f4)      echo "dsv4-0731-f4";;
  pp4)     echo "dsv4-0731-pp4full";;
esac; }

sync_router() {   # leader 漂移自愈: 从实况 pods 取角色 leader IP
  local pf dc
  pf=$(kubectl -n $NS get pod prefill-dsv4-0731-0 -o jsonpath='{.status.podIP}')
  dc=$(kubectl -n $NS get pod decode-dsv4-0731-0  -o jsonpath='{.status.podIP}')
  [ -n "$pf" ] && [ -n "$dc" ] || die "leader pod 未就绪"
  log "leader sync: prefill=$pf decode=$dc"
  kubectl -n $NS set env deploy/deepseek-v4-0731-router \
    PD_PREFILL_ENDPOINTS=$pf:8000 PD_DECODE_ENDPOINTS=$dc:8200 >/dev/null
  kubectl -n $NS scale deploy/deepseek-v4-0731-router --replicas=0 >/dev/null; sleep 5
  kubectl -n $NS scale deploy/deepseek-v4-0731-router --replicas=1 >/dev/null
}

wait_ready() {
  local full code i bad=0
  for i in $(seq 1 120); do
    full=$(kubectl -n $NS get pods --no-headers 2>/dev/null | grep -E "^(decode|prefill)-dsv4-0731" | grep -cE "2/2|1/1")
    code=$(curl -s -m 60 -o /dev/null -w "%{http_code}" http://$(kubectl -n $NS get pod -l app=deepseek-v4-0731-router -o jsonpath='{.items[0].status.hostIP}' 2>/dev/null):8001/v1/chat/completions -X POST -H "Content-Type: application/json" -d '{"model":"DeepSeek-V4-Flash","messages":[{"role":"user","content":"hi"}],"max_tokens":4}')
    [ "$full" = "8" ] && [ "$code" = "200" ] && { log "  ready 8/8 + E2E 200"; return 0; }
    if [ "$full" = "8" ] && { [ "$code" = "503" ] || [ "$code" = "500" ] || [ "$code" = "000" ]; }; then
      bad=$((bad+1)); [ "$bad" -ge 3 ] && { log "  [漂移自愈]"; sync_router; bad=0; }
    else bad=0; fi
    sleep 20
  done
  log "  ❌ wait_ready 超时"; return 1
}

warmup() {
  local R; R=$(kubectl -n $NS get pod -l app=deepseek-v4-0731-router -o jsonpath='{.items[0].status.hostIP}')
  for i in $(seq 1 12); do curl -s -m 90 -o /dev/null http://$R:8001/v1/chat/completions -X POST -H "Content-Type: application/json" -d '{"model":"DeepSeek-V4-Flash","messages":[{"role":"user","content":"Warmup '"$i"': count to twenty."}],"max_tokens":64}'; done
  for i in $(seq 1 8); do curl -s -m 150 -o /dev/null http://$R:8001/v1/chat/completions -X POST -H "Content-Type: application/json" -d '{"model":"DeepSeek-V4-Flash","messages":[{"role":"user","content":"Warm '"$i"': waves."}],"max_tokens":128}' & done; wait; sleep 20
  log "[warmup] done"
}

deploy_form() {   # $1=form
  local dir; dir=$(form_dir "$1")
  [ -f "$dir/site-config.env" ] || die "缺 $dir/site-config.env（从 .example 拷贝填写）"
  log "===== 部署形态 $1 ($dir) ====="
  python3 $METAX/tools/render_site.py "$dir" || die "渲染失败"
  kubectl apply -k "$dir/_rendered/lws/" >/dev/null || die "apply 失败"
  sleep 15; sync_router; wait_ready || die "$1 未就绪"
}

verify_footprint() {   # 抽查 prefill/decode 各 1 节点: sglbench::schedul 进程数与每卡显存
  local pf dc
  pf=$(kubectl -n $NS get pod prefill-dsv4-0731-0 -o jsonpath='{.status.podIP}')
  dc=$(kubectl -n $NS get pod decode-dsv4-0731-0  -o jsonpath='{.status.podIP}')
  for ip in $pf $dc; do
    log "[footprint] node $ip:"
    timeout 25 ssh -o BatchMode=yes ubuntu@$ip "sudo -n mx-smi 2>/dev/null | grep -cE 'sglang::schedul'; sudo -n mx-smi 2>/dev/null | grep -oE '[0-9]+/65536 MiB' | head -8" 2>&1 | sed 's/^/    /'
  done
  log "  (期望: 全量形态 = 8 进程 + 8×~50GB)"
}

verify_graph() {   # decode 实际 graph 档
  log "[graph] $(kubectl -n $NS logs decode-dsv4-0731-0 -c modelserver 2>/dev/null | grep -oE 'Cuda graph decode max bs is adjusted to [0-9]+' | tail -1)"
}

run_s() { local sc=$1 lab=$2 E=$3; shift 3; local rc att
  for att in 1 2; do
    log "> $sc [$lab] attempt$att"
    (cd $SGLB && timeout 4200 python3 -m sglbench run --scenario "$sc" --exec kubectl --label "$lab" \
      --env-file "envs/$E.json" --set model=DeepSeek-V4-Flash \
      --set tokenizer=/workspace/data/DeepSeek-V4-Flash-0731-W8A8 "$@" --timeout 55m --fail-on-bad 2>&1 | tail -2)
    rc=${PIPESTATUS[0]}
    [ "$rc" = "0" ] && return 0
    log "  attempt$att rc=$rc -> 恢复重试"; wait_ready || return 1; warmup
  done; return 1
}
run_mt() { local lab=$1 E=$2
  log "> multiturn-20x10 [$lab]"
  (cd $SGLB && timeout 5400 python3 -m sglbench multiturn --scenario hicache-multiturn-20x10 \
    --label "$lab" --scenario-file envs/scenarios-0731-override.json --env-file "envs/$E.json" --timeout-s 600 2>&1 | tail -4)
}

battery() {   # $1=form（标准对照电池）
  local FORM=$1 E; E=$(form_env "$FORM"); local P="dsv4-0731-cmp-$FORM"
  log "===== [$FORM] 电池开始 (labels $P-*) ====="
  warmup
  run_s single-deepseek-standard "${P}-single5"  "$E" --set num_prompts=5
  run_s single-longctx-deepseek "${P}-longctx5" "$E" --set num_prompts=5
  run_s mini-l2-32c  "${P}-mini32"  "$E" || true
  run_s mini-l2-64c  "${P}-mini64"  "$E" || true
  run_s mini-l2-128c "${P}-mini128" "$E" || true
  run_s conc-32-deepseek "${P}-b32" "$E" || true
  run_s conc-64-deepseek "${P}-b64r1" "$E" || true
  run_s conc-64-deepseek "${P}-b64r2" "$E" || true
  run_s conc-128-deepseek-safe "${P}-b128" "$E" || true
  run_s conc-64-deepseek "${P}-rate2" "$E" --set request_rate=2.0 || true
  run_s conc-64-deepseek "${P}-conc160-rate5" "$E" --set max_concurrency=160 --set request_rate=5.0 --set num_prompts=300 || true
  run_mt "${P}-mt20" "$E"
  log "===== [$FORM] 电池完成 ====="
}

case "${1:-}" in
  footprint)
    for f in ${2:-pernode f4 pp4}; do deploy_form "$f"; verify_footprint; verify_graph; done
    log "FOOTPRINT-DONE";;
  test)
    FORM=${2:?用法: test <pernode|f4|pp4>}
    deploy_form "$FORM"; verify_footprint; verify_graph; battery "$FORM"
    log "TEST-DONE-$FORM";;
  all)
    deploy_form f4;    verify_footprint; verify_graph; battery f4
    deploy_form pp4;   verify_footprint; verify_graph; battery pp4
    deploy_form pernode; verify_footprint
    log "ALL-DONE (末态=pernode)";;
  *) grep -E "^# " "$0" | sed 's/^# //' | head -30;;
esac
