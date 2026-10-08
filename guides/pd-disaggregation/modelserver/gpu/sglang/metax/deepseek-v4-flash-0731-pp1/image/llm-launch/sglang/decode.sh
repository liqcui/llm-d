#!/bin/bash

set -euE
shopt -s inherit_errexit

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$script_dir")"
readonly script_dir project_dir

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

source "$script_dir/common.sh" "$model_spec" "decode"

export EXPERT_RECORD=True

export_multi_arch "NV_SGLANG_GLOO_OPT" "1"


if ! prefill_decode_disaggregation && decode_enable_deepep; then
    decode_chunked_prefill_size=256
    [ -n "${SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK:-}" ] && decode_chunked_prefill_size="$SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK"
else
    decode_chunked_prefill_size="$chunked_prefill_size"
fi
readonly decode_chunked_prefill_size

args=(
    "${prefill_decode_common_args[@]}"
    "${decode_model_args[@]}"
    --chunked-prefill-size="$((decode_chunked_prefill_size * decode_dp_size))"
    --port="$decode_server_port"
    --mem-fraction-static="$decode_mem_fraction_static"
    --max-running-requests="$((decode_max_running_requests * decode_dp_size))"
    --dp-size="$decode_dp_size"
    --ep-size="$decode_ep_size"
    --pp-size="$decode_pp_size"
    --tp-size="$decode_tp_size"
    --enable-dp-lm-head
)

# —— 让实例暴露 /metrics（与 prefill.sh 同一处修复，原因见那边的注释）——
# GPUStack 加在 start_pd.sh 那一层的这三个 flag 到不了 launch_server，
# 镜像里 config.sh:92 的开关又是注释掉的 ⇒ 不补这一下 GPUStack 抓 /metrics 永远 404。
args+=(
    --enable-metrics
    --uvicorn-access-log-exclude-prefixes "/metrics"
    --enable-cache-report
)

if [ "${decode_ep_size:-1}" -gt 1 ]; then
   args+=(
        --moe-dense-tp-size=1
   )
fi


[ "$sglang_version" = "v0.5.7" ] || [ "$sglang_version" = "v0.5.8" ]  || [ "$sglang_version" = "v0.5.12" ] || [ "$sglang_version" = "v0.5.13" ] && {
    args+=(  
        --disable-shared-experts-fusion
    )
}

[ "$decode_dp_size" -gt 1 ] && {
    args+=("--enable-dp-attention")
}

if decode_enable_cuda_graph; then
    # 原始 [1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 14, 16, 18, 20, 22, 24, 26, 28, 30, 32, 40, 48, 56]
    readonly max_bs="$((decode_max_running_requests * decode_dp_size))" #"$decode_max_running_requests"
    for bs in $(seq 8) $(seq 10 2 32) $(seq 36 4 "$max_bs") "$max_bs"; do
        [ "$bs" -le "$max_bs" ] || break
        args_graph_bs+=("$bs")
    done
    readarray -t sorted_graph_bs < <(printf "%s\n" "${args_graph_bs[@]}" | sort -nu)
    #args+=(--cuda-graph-bs "${sorted_graph_bs[@]}")
    args+=(--cuda-graph-max-bs="$max_bs")
else
    args+=(--disable-cuda-graph)
fi

decode_enable_deepep && {
    export FUSED_RMSNORM_QUANT=True
    args+=(
        --moe-a2a-backend="deepep"
        --deepep-mode="low_latency"
        --moe-runner-backend=deep_gemm
        --prefill-round-robin-balance
    )
    # —— bf16 派发（必需，不是性能调优）——
    # 元象镜像自带的 deep_ep（1.0.0+metax3.8.1.1torch2.10）里
    # `Buffer.low_latency_dispatch()` **不接受 topk_weights 参数**，而 sglang 0.5.13
    # 只在 fp8 派发时传它（token_dispatcher/deepep.py:831
    #   `**(dict(topk_weights=topk_weights) if use_fp8 else dict())`）⇒
    # CUDA graph capture 阶段必崩：
    #   TypeError: Buffer.low_latency_dispatch() got an unexpected keyword argument
    #              'topk_weights'
    # （2026-09-21 实测，4 节点 decode 走到 Capture cuda graph 才炸）。
    # 门禁在 v0.5.13：更早的 sglang 没有这个 flag，加了会 unrecognized arguments。
    [ "$sglang_version" = "v0.5.13" ] && args+=(--deepep-dispatcher-output-dtype=bf16)
    # ⚠️ 上面那个 CLI flag **单独用不够**：它只改 DeepEPDispatcher.self.use_fp8，
    #    而 `topk_weights` 这个 kwarg 的开关是 _dispatch_core 里的**局部** use_fp8：
    #      need_bf16_dispatch = ... or (backend.is_deep_gemm() and envs.SGLANG_DEEPEP_BF16_DISPATCH.get())
    #      if not need_bf16_dispatch: use_fp8 = True     ← 只加 CLI flag 时它仍是 True
    #    所以必须把这个 env 也设上（版本 env 里也有一份；这里再兜一道）。
    #    2026-09-21 实测：只加 CLI flag ⇒ 崩溃点一字不变，仍是 topk_weights。
    export SGLANG_DEEPEP_BF16_DISPATCH=1
    # —— decode 三件套（0.5.13 必需，与 llm-d 参照 metax/lws/base/decode.yaml 逐条对齐）——
    # 参照只把它们设在 **decode**（prefill.yaml 一个都没有），版本表里也有同名 env
    # （`decode_common_env` 锚点）；这里再兜一道，保证"镜像自带、怎么建模型都不丢"。
    # ⚠️ 只适用于 0.5.13+：本镜像（r4 = 0.5.13）只在 0.5.13 版本上跑，
    #    0.5.12 的栈用的是 c500/glm5 镜像里**另一份**适配层（那份不能带 JIT_DEEPGEMM，
    #    老 masked 内核在 0.5.12 还能用且更快）。
    # 实测（2026-09-21）：缺这三条，4 节点 decode 在 PD warmup 崩在
    #   alloc_extend_swa_tail 的 Triton 内核，驱动报 xnack(0x8)/ATU 地址翻译越界
    #   （GPU 错误异步上报，真正出事的很可能是更早的 MoE 内核）；补上即通过。
    export SGLANG_ENABLE_JIT_DEEPGEMM=1              # MoE 走 JIT deep_gemm（老 masked 内核已不可用）
    export MX_DEEPEP_DISPATCH_PACK_ALIGN_SIZE=256    # MACA DeepEP 派发 pack 对齐
    export MX_ENABLE_FLASH_MLA_METADATA_CACHE=True   # DSv4 的 DSA backend 是 flashmla_*
}

if decode_enable_two_batch_overlap; then
    args+=(--enable-two-batch-overlap)
    [ "$decode_max_running_requests" -ge 32 ] || log_fatal "Enable two-batch overlap only when max_running_requests($decode_max_running_requests) is greater than or equal to 32."
else
   # opt deepep dispatch on NOT two-batch-overlap
   export PIPE_OPT_ON_SHARE=true
fi

if [ "${decode_mtp_num_draft_tokens:-1}" -gt 1 ]; then
    args+=(
        --speculative-num-steps="$((decode_mtp_num_draft_tokens - 1))"
        --speculative-eagle-topk=1
        --speculative-num-draft-tokens="$decode_mtp_num_draft_tokens"
    )
    if [ "$sglang_version" = "v0.5.1" ]; then
        args+=(
            --speculative-algo=NEXTN
            --speculative-draft="$model_path_draft"
        )
    elif [ "$sglang_version" = "v0.5.7" ]; then
        args+=(
            --speculative-algorithm=NEXTN
            --speculative-draft-model-path="$model_path_draft"
        )
    elif [ "$sglang_version" = "v0.5.8" ]; then
        args+=(
            --speculative-algo=EAGLE 
            #--speculative-draft-model-path="$model_path_draft"
        )
     elif [ "$sglang_version" = "v0.5.12" ]; then
        args+=(
            --speculative-algo=EAGLE 
            #--speculative-draft-model-path="$model_path_draft"
        )
     elif [ "$sglang_version" = "v0.5.13" ]; then
        # v0.5.13 删掉了 --speculative-algo 短名，只有 --speculative-algorithm
        # （实测 launch_server --help 里查不到 --speculative-algo）
        args+=(
            --speculative-algorithm=EAGLE
        )
    else
        log_fatal "Unsupported SGLang version: $sglang_version"
    fi
else
    # 目前不开 MTP 开启这个存在问题
    unset NV_SGLANG_GLOO_OPT
    unset "$(arch_str_map_cur_arch "NV_SGLANG_GLOO_OPT")"
fi

#[ "$decode_ep_size" -gt 0 ] && {
#    ep_enum_redundant_experts=$(((256 + (decode_ep_size - 1)) / decode_ep_size * decode_ep_size - 256))
#    [ "$ep_enum_redundant_experts" -ne 0 ] && {
#        args+=(--ep-num-redundant-experts="$ep_enum_redundant_experts")
#    }
#}

if decode_enable_mock_balance; then
    export ENABLE_EP_MOCK_BALANCE=True
elif [ -n "${decode_eplb_file:-}" ]; then {
        export SGLANG_STATIC_EPLB=True
        args+=(
            --enable-eplb
            --init-expert-location="$decode_eplb_file"
            --eplb-rebalance-num-iterations=10000
            #--enable-expert-distribution-metrics
        )
    }
# else
#   export SGLANG_STATIC_EPLB=False
#   args+=(
#            --enable-eplb
#            --eplb-rebalance-num-iterations=10000
#             #---enable-expert-distribution-metrics
#        )
fi

decode_enable_profile && {
    MY_SERVICE_TORCH_PROFILER_DIR_DECODE=./profile/
    readonly decode_profile_env_var_name="MY_SERVICE_TORCH_PROFILER_DIR_DECODE"
    export SGLANG_TORCH_PROFILER_DIR="${!decode_profile_env_var_name}"
    [ -n "$SGLANG_TORCH_PROFILER_DIR" ] || log_fatal "Profiling enabled but environment variable '$decode_profile_env_var_name' is not set."
    mkdir -p "$SGLANG_TORCH_PROFILER_DIR"
    # 在开启 profile 的情况下需要 disable-overlap-schedule，否则存在 decode 存在段错误
    # v0.5.1 和 v0.5.7 都存在这个问题
    #printf "%s\n" "${args[@]}" | grep -q -- '--disable-overlap-schedule' || {
        #args+=(--disable-overlap-schedule)
    #}
}

show_filtered_env
readarray -d '' -t args < <(sort_args "${args[@]}")
exit_code=0
(set -x; python3 -m sglang.launch_server "${args[@]}") || readonly exit_code="$?"

decode_enable_profile  && {
    # 清理没有保存 profile 结果的空目录
    rmdir "$SGLANG_TORCH_PROFILER_DIR" 2>/dev/null || true
}

exit "$exit_code"
