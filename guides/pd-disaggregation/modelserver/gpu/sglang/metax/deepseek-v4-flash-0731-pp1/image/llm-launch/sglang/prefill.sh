#!/bin/bash

set -euE
shopt -s inherit_errexit

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$script_dir")"
readonly script_dir project_dir

export SGLANG_DYNAMIC_CHUNKING_SMOOTH_FACTOR=0.75

# shellcheck source=../utils/error.sh
source "$project_dir/utils/error.sh"

[ "$#" -eq 4 ] || {
    echo "Usage: $0 <model spec> <master node ip> <nnodes> <node rank>" >&2
    exit 1
}

readonly model_spec="$1"
readonly master_node_ip="$2"
readonly nnodes="$3"
readonly node_rank="$4"

source "$script_dir/common.sh" "$model_spec" "prefill"

export_multi_arch "ENABLE_MACA_SGLANG_GROUPED_GEMM_NVTLASS_INT8" "1" # v0.5.1
export FUSED_RMSNORM_QUANT_PREFILL=1
export SGLANG_PREFILL_SERVER=1
[ "$sglang_version" = "v0.5.1" ] && {
    export SGLANG_TTFT_IMMEDIATE_PP_POSTPROCESS=1
    export SGLANG_TTFT_PREFILL_PP2_OPT=1
}
export SGL_CHUNKED_PREFIX_CACHE_THRESHOLD=0

# —— PP/TP：`MY_PREFILL_PP_AUTO=1` 时按「节点数 + 模型 o_groups」推导 ——
# 老逻辑（config.sh:49）是 pp=env 里写死、tp=nnodes*num_dies/pp；而 DSv4 要求
# **tp 整除 o_groups**（否则 n_local_groups=0，第一个 forward 崩
# `RuntimeError: shape '[4, 0, -1]' is invalid for input of size 4096`），
# 于是写死的 pp 一换节点数就出事：4 节点要 pp4，写 pp1 得 tp32、8 节点写 pp4 得 tp16。
# 推导规则见 auto_pp.sh 顶部注释（num_dies=8、o_groups=8 ⇒ 恒为 tp8 / pp=nnodes）。
# ⚠️ 开关是**独立 env**，不是把 prefill_pp_size_default 写成 "auto"：那个值会被
#    config.sh:49 拿去做 `$((nnodes*num_dies/pp))` 的算术（写成 auto ⇒ 参数当 0 ⇒ 除零）。
source "$script_dir/auto_pp.sh"
o_groups="$(resolve_o_groups "$model_path")"
if [ "${MY_PREFILL_PP_AUTO:-0}" = "1" ]; then
    read -r pp_size tp_size < <(derive_pp_tp "$nnodes" "$num_dies" "$model_path") \
        || log_fatal "PP/TP 自适配失败：nnodes=$nnodes num_dies=$num_dies o_groups=$o_groups"
    echo "[INFO] PP/TP auto: pp=${pp_size} tp=${tp_size} (nnodes=${nnodes} num_dies=${num_dies} o_groups=${o_groups})"
else
    case "$prefill_pp_size_default" in
        '' | *[!0-9]*) log_fatal "prefill_pp_size_default='${prefill_pp_size_default:-}' 既不是正整数、也没开 MY_PREFILL_PP_AUTO" ;;
    esac
    pp_size="$prefill_pp_size_default"
    tp_size="$((nnodes * num_dies / pp_size))"
fi
# 两种模式都拦：算出来的 tp 不整除 o_groups 时，与其 5 分钟后崩在 warmup 里，不如现在退。
[ $((o_groups % tp_size)) -eq 0 ] || log_fatal \
    "tp=${tp_size} 不整除模型 o_groups=${o_groups}：DSv4 的 n_local_groups 会变成 0，第一个 forward 必崩（RuntimeError: shape '[N, 0, -1]'）。把 prefill_pp_size_default 设成 auto，或保证 pp >= nnodes。"

[ "$pp_size" -gt 1 ] && {
    SGLANG_PP_LAYER_PARTITION="$(get_pp_layer_partition "$pp_size")"
    export SGLANG_PP_LAYER_PARTITION
}

args=(
    "${prefill_decode_common_args[@]}"
    "${prefill_model_args[@]}"
    --chunked-prefill-size="$((chunked_prefill_size * prefill_dp_size))"
    --disable-cuda-graph
    # --disable-overlap-schedule
    --max-running-requests="$((prefill_max_running_requests_pre_batch * prefill_dp_size))"
    --mem-fraction-static="$prefill_mem_fraction_static"
    --port="$prefill_server_port"
    --dp-size="$prefill_dp_size"
    --pp-size="$pp_size"
    --tp-size="$tp_size"

)

# —— 让实例暴露 /metrics 并带上缓存命中报告 ——
# ⚠️ 必须在这里自己加：GPUStack 会把这三个 flag 加在 **start_pd.sh 那一层**
#    （`sglang.py:_build_command_args` → `--enable-metrics --uvicorn-access-log-exclude-prefixes
#    /metrics --enable-cache-report`），而本脚本只从 start_pd.sh 收到 4 个位置参数，
#    其余 argv **全部被丢掉** ⇒ launch_server 从来没拿到过它们，
#    于是 GPUStack 每 3 秒抓一次 `/metrics` 都是 404（2026-09-21 实测）。
#    镜像里 config.sh:92 的同名开关也是**被注释掉**的（原作者默认关）。
#    `--enable-cache-report` 让响应里带 cached_tokens —— 验 hicache 命中要靠它。
#    （同一处修复见 pack/sglang-dsv4-c500-patch/patch_enable_metrics.py，那是 c500 镜像的做法。）
args+=(
    --enable-metrics
    --uvicorn-access-log-exclude-prefixes "/metrics"
    --enable-cache-report
)

[ "$sglang_version" = "v0.5.7" ] && args+=(
        --disable-shared-experts-fusion
        --enable-attn-tp-input-scattered
    )

# ⚠️ 这里**不要**加 --decode-attention-backend。prefill 角色本来不跑 decode 分支，
#    而 DSv4 模型每次 forward 都会调 attn_backend.get_swa_out_cache_loc()
#    （deepseek_v4.py:556），该方法只定义在 DeepseekV4*Backend 上。只要
#    decode_backend != prefill_backend，model_runner 就会包一层 HybridAttnBackend
#    （layers/attention/hybrid_attn_backend.py，没有 __getattr__ 转发），
#    第一个 forward（含 PD warmup）必崩：
#      AttributeError: 'HybridAttnBackend' object has no attribute
#                      'get_swa_out_cache_loc'
#    2026-09-21 实测：--decode-attention-backend=flashinfer 时 8 个 rank 全崩。
#    hicache 与 attn backend 无耦合（hybrid 直连版本全栈 dsv4 也能用 hicache）。
enable_hierarchical_radix_cache || enable_mooncake_store && args+=(
        --enable-hierarchical-cache
        --hicache-io-backend="direct" # choices=["direct", "kernel", "kernel_ascend"],
    )

enable_mooncake_store && args+=(
        --hicache-storage-backend=mooncake
        --hicache-storage-prefetch-policy=timeout
    )

! prefill_enable_radix_cache && ! enable_hierarchical_radix_cache && ! enable_mooncake_store && args+=(
    --disable-radix-cache
)

prefill_enable_profile && {
    readonly prefill_profile_env_var_name="MY_SERVICE_TORCH_PROFILER_DIR_PREFILL"
    export SGLANG_TORCH_PROFILER_DIR="${!prefill_profile_env_var_name}"
    [ -n "$SGLANG_TORCH_PROFILER_DIR" ] || log_fatal "Profiling enabled but environment variable '$prefill_profile_env_var_name' is not set."
    mkdir -p "$SGLANG_TORCH_PROFILER_DIR"
}

show_filtered_env
readarray -d '' -t args < <(sort_args "${args[@]}")
exit_code=0
(set -x; python3 -m sglang.launch_server "${args[@]}") || readonly exit_code="$?"

prefill_enable_profile && {
    # 清理没有保存 profile 结果的空目录
    rmdir "$SGLANG_TORCH_PROFILER_DIR" 2>/dev/null || true
}

exit "$exit_code"
