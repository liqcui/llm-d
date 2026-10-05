#!/opt/conda/bin/python3
# ═══════════════════════════════════════════════════════════════════════════
# L2-PP1 镜像补丁 (2026-10-05): 使 r4-hicache-l2 的 prefill.sh 支持最优解拓扑
# (pp1/tp8/dp4)。
#
# 背景: prefill.sh 非 auto 路径 tp_size=$((nnodes*num_dies/pp_size)), pp=1 → tp=32 →
#   触发 o_groups(8) 整除守卫 log_fatal, 无法表达 dsv4rc3 最优的 pp1/tp8/dp4。
#   config.sh:52 已存在 `readonly prefill_tp_size="8"` (厂商默认即 8)。
#
# 补丁: tp 优先取 prefill_tp_size (存在时), 否则回退原公式。
#   效果: PD_PP_SIZE=1 + PD_DP_SIZE=4 → tp=8/pp=1/dp=4 = 最优解拓扑 ✓
#   原 pp4 用法不受影响 (pp=4 时公式给 tp=8, 与 prefill_tp_size 相同)。
# ═══════════════════════════════════════════════════════════════════════════
import sys

PREFILL_SH = "/workspace/llm-launch/sglang/prefill.sh"

OLD = '''    pp_size="$prefill_pp_size_default"
    tp_size="$((nnodes * num_dies / pp_size))"'''

NEW = '''    pp_size="$prefill_pp_size_default"
    # [L2-PP1-patch] 显式 tp 优先: config.sh 的 prefill_tp_size (readonly, 厂商默认 8);
    # 使其支持 pp1/tp8/dp4 最优解拓扑 (原公式 pp=1 → tp=32 触发 o_groups 守卫)。
    tp_size="${prefill_tp_size:-$((nnodes * num_dies / pp_size))}"'''


def main() -> None:
    src = open(PREFILL_SH).read()
    if "[L2-PP1-patch]" in src:
        print("[patch] already applied; skip")
        return
    if OLD not in src:
        print("[patch][FAIL] target block not found in prefill.sh (image changed?)", file=sys.stderr)
        sys.exit(1)
    open(PREFILL_SH, "w").write(src.replace(OLD, NEW, 1))
    print("[patch] prefill.sh tp derivation patched (L2-PP1)")


if __name__ == "__main__":
    main()
