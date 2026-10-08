# shellcheck shell=bash
# shellcheck disable=SC2034

readonly model_path_specific="/workspace/data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8"
#readonly decode_eplb_file_specific="/metax0402/lgao/llm-launch/deepseek_v4-flash.pt"
readonly decode_max_running_requests_default="${decode_max_running_requests_specific:-40}"
readonly decode_mtp_default="${decode_mtp_specific:-3}"
readonly prefill_pp_size_default=8
#2500 3500  2k 新能更好
readonly chunked_prefill_size_default=4096 #4096
#readonly decode_dp_size_default=4
#readonly decode_ep_size_default=1

#export SGLANG_DSV4_FIX_TP_ATTN_A2A_SCATTER=False

export SGLANG_TORCH_PROFILER_DIR="/metax0402/lgao/profile0618"
readonly DIST_PORT=5555
export SGLANG_DISAGGREGATION_BOOTSTRAP_TIMEOUT=6000

#export SGLANG_ENABLE_JIT_DEEPGEMM=False


#export TILELANG_VERBOSE=1

export MC_MAX_EP_PER_CTX=131072

#大输入更好
export SGLANG_DYNAMIC_CHUNKING_SMOOTH_FACTOR=0

export MX_ENABLE_TILELANG_INT_MQA_LOGITS=True

get_prefill_mem_fraction_static() {
    local -r l_tp_size="$1"
    echo "0.80"
    true
}

# ⚠️ decode 的 --mem-fraction-static 是**查表**来的，key = (gpu_name, dp_size, mtp)，
#    而 dp_size 由适配层自己算（config.sh:70-72：tp = dp = nnodes*num_dies），
#    不看 GPUStack 传的 --tp-size/--pp-size ⇒ 4 节点一定落在 dp=32。
#    原表没有 (metax-c500,32,3) 这一行 ⇒ 启动即
#        Fatal: Table lookup failed ... 'metax-c500 32 3'
#    （prefill 不查表、恒返回 0.80，所以同一个镜像里只有 decode 崩。）
#    已补：(c500,32,3) 4 节点、(c500,16,3) 2 节点，取 0.80 = 与表内所有 mtp=3 行一致。
#    其它 dp 值（如 3 节点 = dp24）本表同样没有，要各自补行。
#    同一处修复见 pack/sglang-dsv4-c500-patch/patch_decode_mem_table.py（c500 镜像的做法）。
#
# ⚠️⚠️ 下面 l_table 是**双引号字符串**，表内注释有两条禁忌（2026-09-21 两条都实撞过）：
#    ① 不能出现反引号 —— bash 当命令替换执行，启动即 Fatal + KV: command not found；
#    ② 不能出现双引号 —— 会提前闭合字符串，后面整段表被当 shell 代码解析，
#       报 local: ...: not a valid identifier。
#    所以：**解释写在函数外面（就是上面这段），表内只放纯数据**。
get_decode_mem_fraction_static() {
    local -r l_gpu_name="$1"
    local -r l_dp_size="$2"
    local -r l_mtp="$3"
    local -r l_enable_eplb="$4"
    local -r l_table="
          mem,   gpu_name, dp_size, mtp
        0.80, metax-c500,       8,  3   # 1D1: dp=8 mtp=3
        0.80, metax-c500,       4,  3   # 文档 §8.3 已验证行
        0.80, metax-c500,      32,  3   # 4 节点合一 decode (dp=32/ep=32)
        0.80, metax-c500,      16,  3   # 2 节点合一 decode (dp=16/ep=16)
        0.80, metax-c550,      32,  3
        0.82, metax-c550,      32,  2
        0.80, metax-c550,       4,  3 # tokens: 106176
        0.81 , metax-c550,      32,  4 # tokens: 72768
        0.79 , metax-c550,       4,  2 # tokens: 72768
        0.80, metax-c550,      64,  3
        0.80, metax-c550,      16,  3
        0.80, metax-c550,      16,  2
        0.80, metax-c550,       1,  3
        0.80, metax-c550,      16,  4

        0.804,  mars-x201,      16,  2
        0.76 ,  mars-x201,      16,  3
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
        echo "6,5,5,5,6,5,6,5"
    elif [ "$l_pp_size" -eq 4 ]; then
        echo "11,11,11,10"
    elif [ "$l_pp_size" -eq 2 ]; then
        echo "22,21"
    else
        log_fatal "Unsupported PP size $l_pp_size"
    fi
    true
}

readonly prefill_model_args=(
    #--attention-backend=flashinfer
    --enable-dynamic-chunking
    #--attn-cp-size 2
    #--enable-prefill-context-parallel
    #--nsa-prefill-cp-mode round-robin-split 
    --swa-full-tokens-ratio 0.4
    --pp-async-batch-depth 2
)
readonly decode_model_args=(
    # --attention-backend=flashinfer
    --swa-full-tokens-ratio 0.1 #0.4
)
readonly prefill_decode_model_args=(
    --tool-call-parser deepseekv4 
    --reasoning-parser deepseek-v4 
    --kv-cache-dtype bf16
    --quantization w8a8_int8

)
