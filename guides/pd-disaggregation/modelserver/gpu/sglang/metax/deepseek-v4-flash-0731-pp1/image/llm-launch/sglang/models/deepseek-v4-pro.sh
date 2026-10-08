# shellcheck shell=bash
# shellcheck disable=SC2034

readonly model_path_specific="/metax0402/metax0402/models/metax-tech/DeepSeek-V4-Pro-W8A8/"
#readonly decode_eplb_file_specific="/metax0402/lgao/llm-launch/deepseek_v4.pt"
readonly decode_max_running_requests_default=8
readonly decode_mtp_default=3
readonly chunked_prefill_size_default=4096
#readonly decode_dp_size_default=16
readonly prefill_pp_size_default=6
#export SGLANG_DSV4_FIX_TP_ATTN_A2A_SCATTER=False

export DEEPEP_MORE_EXPERTS=1

readonly DIST_PORT=5555

export SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=6000
#export SGLANG_TOPK_TRANSFORM_512_TORCH=True
export SGLANG_TORCH_PROFILER_DIR="/metax0402/lgao/profile0626"

export MC_NUM_QP_PER_EP=1
export MC_MAX_EP_PER_CTX=131072

get_prefill_mem_fraction_static() {
    local -r l_tp_size="$1"
    echo "0.80"
    true
}

get_decode_mem_fraction_static() {
    local -r l_gpu_name="$1"
    local -r l_dp_size="$2"
    local -r l_mtp="$3"
    local -r l_enable_eplb="$4"
    local -r l_table="
          mem,   gpu_name, dp_size, mtp
        0.76, metax-c550,      16,  3
        0.81 , metax-c550,     96,  2 # tokens: 72768
        0.78 , metax-c550,     64,  3 # tokens: 72768
        0.79 , metax-c550,     64,  2
        0.78 , metax-c550,     8,  3
        0.78 , metax-c550,     128,  3
        0.80 , metax-c550,     96,  3

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
    if [ "$l_pp_size" -eq 8 ]; then
        echo "8,8,8,8,8,7,7,7"
    elif [ "$l_pp_size" -eq 4 ]; then
        echo "16,16,15,14"
    elif [ "$l_pp_size" -eq 6 ]; then
        echo "11,10,10,10,10,10"
    else
        log_fatal "Unsupported PP size $l_pp_size"
    fi
    true
}

readonly prefill_model_args=(
    #--attention-backend=flashinfer
    #--attn-cp-size 4
    #--enable-prefill-context-parallel
    #--nsa-prefill-cp-mode round-robin-split 
    --enable-dynamic-chunking 
    --swa-full-tokens-ratio 0.1
)
readonly decode_model_args=(
    # --attention-backend=flashinfer
    --swa-full-tokens-ratio 0.1
)
readonly prefill_decode_model_args=(
    --tool-call-parser deepseekv4 
    --reasoning-parser deepseek-v4 
    --kv-cache-dtype bf16
    --quantization w8a8_int8

)
