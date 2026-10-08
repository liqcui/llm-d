# shellcheck shell=bash
# shellcheck disable=SC2034

readonly model_path_specific="/bgfs/models/llm/DeepSeek/DeepSeek-R1-bf16_W8A8/vllm_quant_model"
readonly decode_eplb_file_specific="/bgfs/deepseek-pd/eplb/decode-ep64-sgl051/expert_distribution_recorder_1020_32k_cnt.pt"
readonly decode_max_running_requests_default=32
readonly decode_mtp_default=2

get_prefill_mem_fraction_static() {
    local -r l_tp_size="$1"
    echo "0.76"
    true
}

# deepseek: ep32 每 0.01 变动 8421 token
get_decode_mem_fraction_static() {
    local -r l_gpu_name="$1"
    local -r l_dp_size="$2"
    local -r l_mtp="$3"
    local -r l_enable_eplb="$4"
    echo "0.804"
    true
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
    --attention-backend=flashinfer
)
readonly prefill_decode_model_args=()
