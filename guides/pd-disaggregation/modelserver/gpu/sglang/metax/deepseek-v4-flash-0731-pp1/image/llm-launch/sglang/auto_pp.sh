#!/bin/bash
# auto_pp.sh —— 按「节点数 + 模型 o_groups」推导 PP/TP，供 sglang/prefill.sh source。
#
# 为什么要它
# ----------
# 适配层原本是：pp = prefill_pp_size_default（版本 env 里写死），
#               tp = nnodes * num_dies / pp（config.sh:49）。
# 而 DSv4 的注意力输出要按 n_local_groups = o_groups / tp reshape
# （deepseek_v4.py:990 `o.view(o.shape[0], self.n_local_groups, -1)`），
# **tp 不整除 o_groups 时 n_local_groups=0**，第一个 forward 就崩：
#     RuntimeError: shape '[4, 0, -1]' is invalid for input of size 4096
#
# 于是「写死的 pp」在换节点数时必然出事：4 节点 × 8 卡要 pp4（tp8），
# 写成 pp1 得 tp32、扩到 8 节点写成 pp4 得 tp16 —— 同一个崩。
#
# 规则
# ----
#   tp := 「整除 o_groups 的最大可用值」（不再看 env 里写死的 pp）
#   pp := nnodes * num_dies / tp
# num_dies=8、o_groups=8 时恒有 tp8 / pp=nnodes ⇒ 1/2/4/8 节点都是对的形状；
# 每节点卡数更少时 tp 自动变小（1 节点 × 4 卡 → tp4/pp1）。
#
# 提供的函数
# ----------
#   resolve_o_groups [model_path]         -> 打印 o_groups
#   derive_pp_tp <nnodes> <num_dies> [model_path] -> 打印 "<pp> <tp>"（失败返回 1）
#
# 只定义函数、不产生副作用（可以被单测直接 source，见 tests/pack/test_auto_pp.py）。
#
# ⚠️ 局部变量一律加 `l_` 前缀：适配层把 `model_path` / `num_dies` / `gpu_name` /
#    `local_ip` 等做成了 **readonly 全局**（common.sh:28、config.sh），函数里写
#    `local model_path=...` 会当场
#        /workspace/llm-launch/sglang/auto_pp.sh: line 33: local: model_path: readonly variable
#    并以 exit 1 结束整个 prefill（2026-09-21 首次上线就是这么挂的）。
#    单测里没这个上下文，所以 tests/pack/test_auto_pp.py 专门带 readonly 前导跑一遍。

# o_groups 取值顺序：env 显式覆盖 → 模型 config.json → DSv4 家族默认 8。
# ⚠️ 读到非数字/非法值时**回落到 8**，绝不把脏值往外传（否则会推出一个假拓扑）。
resolve_o_groups() {
    local -r l_model_path="${1:-}"
    local l_value=""

    if [ -n "${MY_PREFILL_O_GROUPS:-}" ]; then
        l_value="$MY_PREFILL_O_GROUPS"
    elif [ -n "$l_model_path" ] && [ -f "${l_model_path%/}/config.json" ]; then
        l_value="$(
            python3 -c '
import json, sys
try:
    v = json.load(open(sys.argv[1])).get("o_groups")
except Exception:
    v = None
print(v if isinstance(v, int) and v > 0 else "")
' "${l_model_path%/}/config.json" 2>/dev/null || true
        )"
    fi

    case "$l_value" in
        '' | *[!0-9]*) l_value=8 ;;
    esac
    [ "$l_value" -gt 0 ] || l_value=8

    printf '%s\n' "$l_value"
}

derive_pp_tp() {
    local -r l_nnodes="${1:-1}"
    local -r l_num_dies="${2:-1}"
    local -r l_model_path="${3:-}"
    local -r l_total="$((l_nnodes * l_num_dies))"
    local -r l_o_groups="$(resolve_o_groups "$l_model_path")"

    local l_tp="" l_divisor
    for ((l_divisor = l_o_groups; l_divisor >= 1; l_divisor--)); do
        if ((l_o_groups % l_divisor == 0 && l_total % l_divisor == 0)); then
            l_tp="$l_divisor"
            break
        fi
    done
    if [ -z "$l_tp" ]; then
        return 1
    fi

    printf '%s %s\n' "$((l_total / l_tp))" "$l_tp"
    return 0
}
