# shellcheck shell=bash
# shellcheck disable=SC2034

readonly model_path_specific="/bgfs/models/llm/GLM/GLM-5-W8A8"
readonly decode_eplb_file_specific="/bgfs/deepseek-pd/eplb/glm5-decode-ep32/expert_distribution_recorder_1773217884.015296_cnt.pt"
readonly decode_max_running_requests_default=32
readonly decode_mtp_default=2

get_prefill_mem_fraction_static() {
    local -r l_tp_size="$1"
    echo "0.84"
    true
}

get_decode_mem_fraction_static() {
    local -r l_gpu_name="$1"
    local -r l_dp_size="$2"
    local -r l_mtp="$3"
    local -r l_enable_eplb="$4"
    local -r l_table="
          mem,   gpu_name, dp_size, mtp, eplb
        0.82 , metax-c550,      32,   2,    1 # tokens: 57792

        0.83 , metax-c550,      32,   3,    0 # tokens: 70720
      # 0.833, metax-c550,      32,   3,    0 # tokens: 72512

        0.83 , metax-c550,      32,   3,    1 # tokens: 63744

        0.759, metax-c550,      64,   3,    0 # tokens: 131840
        0.772, metax-c550,      64,   3,    1 # tokens: 132352

        0.772, metax-c550,      64,   4,    1 # tokens: 149376(disable dp-lm-head)

        0.82 ,  mars-x201,      32,   2,    1
        0.83 ,  mars-x201,      32,   3,    0
        0.83 ,  mars-x201,      32,   3,    1
        0.759,  mars-x201,      64,   3,    0
        0.772,  mars-x201,      64,   3,    1
        0.772,  mars-x201,      64,   4,    1
    "
    local l_mem=""
    l_mem="$(table_lookup "$l_table" 'number' "$l_gpu_name" "$l_dp_size" "$l_mtp" "$l_enable_eplb")"
    echo "$l_mem"
}

get_prefill_dp_size() {
    echo "1"
}

get_pp_layer_partition() {
    local -r l_pp_size="$1"
    if [ "$l_pp_size" -eq 2 ]; then
        echo "40,38"
    elif [ "$l_pp_size" -eq 4 ]; then
        echo "20,20,19,19"
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
