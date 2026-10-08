#!/usr/bin/env python3
"""0731 llm-launch 适配补丁 — 让 0.5.13 系官方 llm-launch 脚本支持 0.5.14 + DSPARK 0731。

背景
----
官方 llm-launch 脚本 (0.5.13-dsv4-adapter-r4 血缘) 对 0.5.14 会 log_fatal
(版本 allow-list 不含 v0.5.14), 且投机解码只有 EAGLE/NEXTN 分支 (0731 需要
DSPARK); FlexSMQ 的 deepep low_latency 路径不适用于本镜像的 ModelSlim MoE
(其 NPU 实现在 MACA 上被补丁替换为 GPU Triton runner, 仅覆盖 standard dispatch)。

改动 (5 处 gate + 1 新 spec)
----------------------------
1. common.sh       版本 allow-list += v0.5.14
2. config.sh       版本 env 块 gate += v0.5.14 (CUDA_KERNEL_ARGS 等)
3. config.sh       model_spec 加载分支 += deepseek-v4-flash-0731
4. config.sh       decode_enable_deepep() → false (0731 镜像专用, MoE 走 Triton)
5. decode.sh       版本 gate += v0.5.14 (PIPE_OPT_ON_SHARE 块)
6. decode.sh       投机解码链 += v0.5.14 → DSPARK 分支 (block 6; 通用 draft 参数跳过)
7. models/deepseek-v4-flash-0731.sh   新建 (0731 模型 spec: DSPARK/400K/16384/...)

用法 (镜像构建内):
    python3 /tmp/apply_0731_llm_launch_patch.py [--check]
"""

import ast
import os
import sys

LL = "/workspace/llm-launch/sglang/"
F_COMMON = LL + "common.sh"
F_CONFIG = LL + "config.sh"
F_DECODE = LL + "decode.sh"
F_SPEC = LL + "models/deepseek-v4-flash-0731.sh"

MARKER = "PATCH-0731"

# --------------------------------------------------------------------------- #
# 1. common.sh — 版本 allow-list
# --------------------------------------------------------------------------- #
C_OLD = """[ "$sglang_version" = "v0.5.1" ] || [ "$sglang_version" = "v0.5.7" ] || [ "$sglang_version" = "v0.5.8" ] || [ "$sglang_version" = "v0.5.12" ] || [ "$sglang_version" = "v0.5.13" ] || log_fatal "Unsupported SGLang version: $sglang_version\""""
C_NEW = """[ "$sglang_version" = "v0.5.1" ] || [ "$sglang_version" = "v0.5.7" ] || [ "$sglang_version" = "v0.5.8" ] || [ "$sglang_version" = "v0.5.12" ] || [ "$sglang_version" = "v0.5.13" ] || [ "$sglang_version" = "v0.5.14" ] || log_fatal "Unsupported SGLang version: $sglang_version\""""

# --------------------------------------------------------------------------- #
# 2. config.sh — spec 加载分支 + 版本 gate + deepep 关闭
# --------------------------------------------------------------------------- #
CFG_SPEC_OLD = """if [ "${model_spec:-}" == "deepseek-v4-flash" ]; then
    source "$_sglang_config_sh_script_dir/models/${model_spec}.sh"
elif [ "${model_spec:-}" == "deepseek-v4-pro" ]; then"""

CFG_SPEC_NEW = """if [ "${model_spec:-}" == "deepseek-v4-flash" ]; then
    source "$_sglang_config_sh_script_dir/models/${model_spec}.sh"
elif [ "${model_spec:-}" == "deepseek-v4-flash-0731" ]; then
    # PATCH-0731: ModelSlim W8A8 0731 (DSPARK, 400K, 0.5.14)
    source "$_sglang_config_sh_script_dir/models/${model_spec}.sh"
elif [ "${model_spec:-}" == "deepseek-v4-pro" ]; then"""

CFG_VER_OLD = """[ "$sglang_version" = "v0.5.7" ]  || [ "$sglang_version" = "v0.5.8" ] || [ "$sglang_version" = "v0.5.12" ] || [ "$sglang_version" = "v0.5.13" ] && {"""
CFG_VER_NEW = """[ "$sglang_version" = "v0.5.7" ]  || [ "$sglang_version" = "v0.5.8" ] || [ "$sglang_version" = "v0.5.12" ] || [ "$sglang_version" = "v0.5.13" ] || [ "$sglang_version" = "v0.5.14" ] && {"""

CFG_DEEPEP_OLD = """    decode_enable_deepep() {
        true
    }"""
CFG_DEEPEP_NEW = """    decode_enable_deepep() {
        # PATCH-0731: 0731 (ModelSlim W8A8) MoE 走 GPU Triton runner,
        # 不启用 DeepEP 低延迟路径 (委托实现仅覆盖 standard dispatch)
        false
    }"""

# --------------------------------------------------------------------------- #
# 3. decode.sh — 版本 gate + DSPARK 分支
# --------------------------------------------------------------------------- #
DEC_VER_OLD = """[ "$sglang_version" = "v0.5.7" ] || [ "$sglang_version" = "v0.5.8" ]  || [ "$sglang_version" = "v0.5.12" ] || [ "$sglang_version" = "v0.5.13" ] && {"""
DEC_VER_NEW = """[ "$sglang_version" = "v0.5.7" ] || [ "$sglang_version" = "v0.5.8" ]  || [ "$sglang_version" = "v0.5.12" ] || [ "$sglang_version" = "v0.5.13" ] || [ "$sglang_version" = "v0.5.14" ] && {"""

DEC_MT_OLD = """if [ "${decode_mtp_num_draft_tokens:-1}" -gt 1 ]; then
    args+=(
        --speculative-num-steps="$((decode_mtp_num_draft_tokens - 1))"
        --speculative-eagle-topk=1
        --speculative-num-draft-tokens="$decode_mtp_num_draft_tokens"
    )"""
DEC_MT_NEW = """if [ "${decode_mtp_num_draft_tokens:-1}" -gt 1 ]; then
    # PATCH-0731: v0.5.14 + DSPARK 的 draft 参数由引擎自推导
    # (num_steps=1/topk=1/num_draft_tokens=block_size+1), 不传通用三参数
    if [ "$sglang_version" != "v0.5.14" ]; then
        args+=(
            --speculative-num-steps="$((decode_mtp_num_draft_tokens - 1))"
            --speculative-eagle-topk=1
            --speculative-num-draft-tokens="$decode_mtp_num_draft_tokens"
        )
    fi"""

DEC_BRANCH_OLD = """     elif [ "$sglang_version" = "v0.5.13" ]; then
        # v0.5.13 删掉了 --speculative-algo 短名，只有 --speculative-algorithm
        # （实测 launch_server --help 里查不到 --speculative-algo）
        args+=(
            --speculative-algorithm=EAGLE
        )
    else
        log_fatal "Unsupported SGLang version: $sglang_version\""""
DEC_BRANCH_NEW = """     elif [ "$sglang_version" = "v0.5.13" ]; then
        # v0.5.13 删掉了 --speculative-algo 短名，只有 --speculative-algorithm
        # （实测 launch_server --help 里查不到 --speculative-algo）
        args+=(
            --speculative-algorithm=EAGLE
        )
    elif [ "$sglang_version" = "v0.5.14" ]; then
        # PATCH-0731: DSPARK (draft 权重在 0731 checkpoint 内, 引擎自动发现;
        # block_size 6 → 引擎推导 num_steps=1/topk=1/num_draft_tokens=7)
        # ⚠ --speculative-draft-model-quantization=modelslim 必需: 否则 draft
        # 走 UnquantizedLinear → int8 原值当 bf16 用 → strip 全部 unexpected
        # (weight_scale/offset 丢弃) → draft 输出乱码 → accept rate ~0
        args+=(
            --speculative-algorithm=DSPARK
            --speculative-dspark-block-size="${decode_dspark_block_size_specific:-6}"
            --speculative-draft-model-quantization=modelslim
        )
    else
        log_fatal "Unsupported SGLang version: $sglang_version\""""

# --------------------------------------------------------------------------- #
# 3.5 prefill.sh — tp 推导优先取 prefill_tp_size (同 L2-PP1 补丁)
# --------------------------------------------------------------------------- #
F_PREFILL = LL + "prefill.sh"

PF_OLD = '''    pp_size="$prefill_pp_size_default"
    tp_size="$((nnodes * num_dies / pp_size))"'''
PF_NEW = '''    pp_size="$prefill_pp_size_default"
    # PATCH-0731 (同 L2-PP1): 显式 tp 优先 — config.sh 的 prefill_tp_size;
    # 支持 pp1/tp8/dp4 最优解拓扑 (原公式 pp=1 → tp=32 触发 o_groups 守卫)
    tp_size="${prefill_tp_size:-$((nnodes * num_dies / pp_size))}"'''

# prefill dp>1 需 dp-attention (镜像 decode.sh 同款; 厂商 prefill 默认 dp=1 无此逻辑,
# RC3 最优拓扑 dp=4 会撞 "multi-node data parallel is not supported unless dp attention!")
PF_DPA_OLD = '''    --dp-size="$prefill_dp_size"
    --pp-size="$pp_size"
    --tp-size="$tp_size"

)'''
PF_DPA_NEW = '''    --dp-size="$prefill_dp_size"
    --pp-size="$pp_size"
    --tp-size="$tp_size"

)

[ "$prefill_dp_size" -gt 1 ] && {
    # PATCH-0731: 镜像 decode.sh 的 dp-attention 处理 (最优拓扑 prefill dp=4);
    # 必须在主 args=(...) 之后追加 (提前追加会被整体赋值覆盖)
    args+=("--enable-dp-attention")
}'''

# --------------------------------------------------------------------------- #
# 4. 新建 spec: models/deepseek-v4-flash-0731.sh
# --------------------------------------------------------------------------- #
SPEC_CONTENT = """# shellcheck shell=bash
# shellcheck disable=SC2034
# PATCH-0731: DeepSeek-V4-Flash-0731-w8a8 (ModelSlim W8A8) on 0.5.14-maca
# 基准参数 = 用户 0.5.14 验证配置 (单节点直启实测闭环):
#   DSPARK block 6 / context 400K / chunked 16384 / kv bfloat16 / sched 0.6

readonly model_path_specific="/workspace/data/DeepSeek-V4-Flash-0731-w8a8"
readonly decode_eplb_file_specific=""
readonly decode_max_running_requests_default="${decode_max_running_requests_specific:-10}"
# DSPARK: draft 数 = block_size + 1 = 7 (引擎自推导; 此值同时用于 mem 表查找)
readonly decode_mtp_default="${decode_mtp_specific:-7}"
readonly prefill_pp_size_default=1
readonly chunked_prefill_size_default=16384
readonly context_length_specific=400000
# DSPARK 块大小 (decode.sh v0.5.14 分支读取)
readonly decode_dspark_block_size_specific=6
#readonly decode_dp_size_default=4
#readonly decode_ep_size_default=8

# ── 用户 0.5.14 验证 env ──
export PYTORCH_ENABLE_PG_HIGH_PRIORITY_STREAM=1
export MACA_SMALL_PAGESIZE_ENABLE=1
export CUDA_GRAPH_DP_USE_SUM_BS=False
export SGLANG_DSPARK_KERNEL_COMMIT_KV_PROJ=torch
# 400K 上下文超模型默认, 必须允许覆盖
export SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1

# Mooncake PD KV 传输 (MACA 传输桥; 缺此 env 传输全失败)
export MC_MACA_HOST_TRANSPORT=1

get_prefill_mem_fraction_static() {
    local -r l_tp_size="$1"
    echo "0.82"
    true
}

get_decode_mem_fraction_static() {
    local -r l_gpu_name="$1"
    local -r l_dp_size="$2"
    local -r l_mtp="$3"
    local -r l_enable_eplb="$4"
    local -r l_table="
          mem,   gpu_name, dp_size, mtp
        0.75, metax-c500,       4,  7
        0.75, metax-c500,       8,  7
        0.75, metax-c500,       4,  3
        0.75, metax-c500,       8,  3
    "
    local l_mem=""
    l_mem="$(table_lookup "$l_table" 'number' "$l_gpu_name" "$l_dp_size" "$l_mtp")"
    echo "$l_mem"
}

get_prefill_dp_size() {
    echo "4"
}

readonly prefill_model_args=(
)

readonly decode_model_args=(
)

readonly prefill_decode_model_args=(
    --tool-call-parser deepseekv4
    --reasoning-parser deepseek-v4
    --kv-cache-dtype bfloat16
)
"""

PATCHES = [
    ("common.sh:version", F_COMMON, C_OLD, C_NEW, 1),
    ("config.sh:spec-branch", F_CONFIG, CFG_SPEC_OLD, CFG_SPEC_NEW, 1),
    ("config.sh:version-gate", F_CONFIG, CFG_VER_OLD, CFG_VER_NEW, 1),
    ("config.sh:deepep", F_CONFIG, CFG_DEEPEP_OLD, CFG_DEEPEP_NEW, 1),
    ("decode.sh:version-gate", F_DECODE, DEC_VER_OLD, DEC_VER_NEW, 1),
    ("decode.sh:mtp-args", F_DECODE, DEC_MT_OLD, DEC_MT_NEW, 1),
    ("decode.sh:dspark-branch", F_DECODE, DEC_BRANCH_OLD, DEC_BRANCH_NEW, 1),
    ("prefill.sh:tp-derivation", F_PREFILL, PF_OLD, PF_NEW, 1),
    ("prefill.sh:dp-attention", F_PREFILL, PF_DPA_OLD, PF_DPA_NEW, 1),
]


def main() -> None:
    check_only = "--check" in sys.argv
    for name, path, old, new, expect in PATCHES:
        src = open(path).read()
        if old not in src:
            print(f"[skip] {name}: 已打过补丁 (或文本不匹配)")
            continue
        n = src.count(old)
        if n != expect:
            sys.exit(f"[FAIL] {name}: 锚点匹配 {n} 次 (期望 {expect})")
        if check_only:
            print(f"[ok] {name}")
            continue
        src = src.replace(old, new, expect)
        open(path, "w").write(src)
        print(f"[applied] {name}")

    # 新 spec 文件
    if MARKER in (open(F_SPEC).read() if os.path.exists(F_SPEC) else ""):
        print("[skip] spec: 已存在")
    elif check_only:
        print("[ok] spec (将新建)")
    else:
        open(F_SPEC, "w").write(SPEC_CONTENT)
        print("[written] models/deepseek-v4-flash-0731.sh")

    print("[PATCH-0731-llm] done" + (" (check only)" if check_only else ""))


if __name__ == "__main__":
    main()
