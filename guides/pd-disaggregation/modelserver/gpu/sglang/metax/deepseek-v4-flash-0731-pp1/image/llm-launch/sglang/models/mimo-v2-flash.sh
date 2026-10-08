# shellcheck shell=bash
# shellcheck disable=SC2034

readonly model_path_specific="/bgfs/models/llm/XiaoMi/MiMo-V2-Flash-W8A8"
readonly chunked_prefill_size_default=$((1024 * 4))
readonly prefill_pp_size_default=1 # pp8tp1: 8, dp8tp8: 1
readonly decode_eplb_file_specific=""
readonly decode_max_running_requests_default=32
readonly decode_mtp_default=2

get_prefill_mem_fraction_static() {
    local -r l_tp_size="$1"
    echo "0.921"
    true
}

get_decode_mem_fraction_static() {
    local -r l_gpu_name="$1"
    local -r l_dp_size="$2"
    local -r l_mtp="$3"
    local -r l_enable_eplb="$4"
    local -r l_table="
          mem,   gpu_name, dp_size, mtp
        0.825, metax-c550,      16,   0
        0.78 , metax-c550,      16,   2

        0.825,  mars-x201,      16,   0
        0.78 ,  mars-x201,      16,   2
    "
    local l_mem=""
    l_mem="$(table_lookup "$l_table" 'number' "$l_gpu_name" "$l_dp_size" "$l_mtp")"
    echo "$l_mem"
}

get_prefill_dp_size() {
    local -r l_nnodes="$1"
    local -r l_num_dies="$2"

    if [ "$prefill_pp_size_default" -eq 1 ]; then
        echo "$((l_nnodes * l_num_dies))"
    else
        echo 1
    fi
}

get_pp_layer_partition() {
    local -r l_pp_size="$1"
    if [ "$l_pp_size" -eq 8 ]; then
        echo "6,6,6,6,6,6,6,6"
    else
        log_fatal "Unsupported PP size $l_pp_size"
    fi
    true
}

prefill_model_args=(
    --moe-runner-backend=cutlass
)
if [ "$prefill_pp_size_default" -eq 1 ]; then
    prefill_model_args+=(--enable-dp-lm-head)
    prefill_model_args+=(--enable-dp-attention)
fi
readonly prefill_model_args
readonly decode_model_args=(
)
readonly prefill_decode_model_args=(
    --swa-full-tokens-ratio=0.2
    --attention-backend=fa3
    --reasoning-parser=mimo
    --tool-call-parser=mimo
)
