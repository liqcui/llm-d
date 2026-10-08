# shellcheck shell=bash
# shellcheck disable=SC2034

readonly model_path_specific="/bgfs/models/llm/Qwen/Qwen3.5-397B-A17B-W8A8/"
readonly decode_eplb_file_specific=""  # 不开启 eplb
readonly decode_max_running_requests_default=32
readonly decode_mtp_default=4
readonly prefill_pp_size_default=1  # prefill 不开 PP

get_prefill_mem_fraction_static() {
    echo "0.80"
    true
}

get_decode_mem_fraction_static() {
    local -r l_gpu_name="$1"
    local -r l_dp_size="$2"
    local -r l_mtp="$3"
    local -r l_enable_eplb="$4"
    echo "0.80"
    true
}

get_prefill_dp_size() {
    echo "1"
}

readonly prefill_model_args=(
    --attention-backend=flashinfer
    --mamba-ssm-dtype=bfloat16
)
readonly decode_model_args=(
    --attention-backend=flashinfer
    --mamba-ssm-dtype=bfloat16
    --max-mamba-cache-size=64
    --max-total-tokens=$((1024 * 64))
)
readonly prefill_decode_model_args=()

export DEEPEP_MORE_EXPERTS=1
export USE_GEMMA_RMSNORM_FUSED_KERNEL=1
export FUSED_RMSNORM_QUANT=1
export FUSED_RMSNORM_QUANT_PREFILL=1
