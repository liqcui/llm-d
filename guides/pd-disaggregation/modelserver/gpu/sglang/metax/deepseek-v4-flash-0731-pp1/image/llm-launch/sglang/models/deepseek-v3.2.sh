# shellcheck shell=bash
# shellcheck disable=SC2034

readonly model_path_specific="/bgfs/models/llm/DeepSeek/DeepSeek-V3.2-W8A8"
readonly decode_eplb_file_specific="/bgfs/deepseek-pd/eplb/decode-ep64-sgl051/expert_distribution_recorder_1020_32k_cnt.pt"
readonly decode_max_running_requests_default=32
readonly decode_mtp_default=2

get_prefill_mem_fraction_static() {
    local -r l_tp_size="$1"
    echo "0.76"
    true
}

get_decode_mem_fraction_static() {
    local -r l_gpu_name="$1"
    local -r l_dp_size="$2"
    local -r l_mtp="$3"
    local -r l_enable_eplb="$4"
    local -r l_table="
          mem,   gpu_name, dp_size, mtp
        0.804, metax-c550,      32,  2
      # 0.804, metax-c550,      32,  3 # tokens: 106176
        0.76 , metax-c550,      32,  3 # tokens: 72768
        0.76 , metax-c550,       4,  2 # tokens: 72768

        0.804,  mars-x201,      32,  2
        0.76 ,  mars-x201,      32,  3
        0.76 ,  mars-x201,       4,  2
    "
    local l_mem=""
    l_mem="$(table_lookup "$l_table" 'number' "$l_gpu_name" "$l_dp_size" "$l_mtp")"
    echo "$l_mem"
}

get_prefill_dp_size() {
    echo "1"
}

get_pp_layer_partition() {
    local -r l_pp_size="$1"
    if [ "$l_pp_size" -eq 2 ]; then
        echo "31,30"
    elif [ "$l_pp_size" -eq 4 ]; then
        echo "16,15,15,15"
    else
        log_fatal "Unsupported PP size $l_pp_size"
    fi
    true
}

readonly prefill_model_args=(
    --attention-backend=flashinfer
)
readonly decode_model_args=(
    # --attention-backend=flashinfer
)
readonly prefill_decode_model_args=()
