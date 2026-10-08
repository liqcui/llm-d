# shellcheck shell=bash
# shellcheck disable=SC2034
# shellcheck disable=SC2154
_sglang_config_sh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_sglang_config_sh_project_dir="$(dirname "$_sglang_config_sh_script_dir")"
readonly _sglang_config_sh_script_dir _sglang_config_sh_project_dir

readonly model_path="$1"
readonly pd_disaggregation_mode="$2"
readonly model_path_draft="$model_path"


readonly hca_list="mlx5_0,mlx5_1" # DeepEP IB 设备 (文档 §8.2)
# Mooncake Store / PD Transfer Engine 用的 IB 设备。可被 env 覆盖（版本表里设）：
#   MY_MOONCAKE_IB_DEVICE=mlx5_0,mlx5_1   ← 双口，团队报告 §4 用的就是双口
# 单口（原默认）会把 Store 的 RDMA 流量和 PD 的 KV 传输挤在同一条 HCA 上。
readonly mooncake_ib_device="${MY_MOONCAKE_IB_DEVICE:-mlx5_0}"


readonly prefill_server_port="30000"
readonly decode_server_port="30001"
readonly minilb_server_port="8001"
readonly mooncake_master_port="50051"
readonly mooncake_metadata_port="8080"

if [ "${model_spec:-}" == "deepseek-v4-flash" ]; then
    source "$_sglang_config_sh_script_dir/models/${model_spec}.sh"
elif [ "${model_spec:-}" == "deepseek-v4-pro" ]; then
    source "$_sglang_config_sh_script_dir/models/${model_spec}.sh"
else
    [ -n "$model_path" ] && {
        model_type="$(get_model_type "$model_path")"
        readonly model_type
        # shellcheck source=./models/deepseek-v3.sh
        source "$_sglang_config_sh_script_dir/models/${model_type}.sh"
    }
fi

# readonly page_size=64
readonly chunked_prefill_size="${chunked_prefill_size_default:-$((1024 * 14))}"

[ "${pd_disaggregation_mode:-}" = "prefill" ] && {
    prefill_enable_radix_cache() {
        true
    }
    prefill_enable_profile() {
        false
    }
    readonly prefill_max_running_requests_pre_batch="64"
    readonly prefill_dp_size=$(get_prefill_dp_size "$nnodes" "$num_dies")
    readonly prefill_pp_size="${prefill_pp_size_default:-2}"
    readonly prefill_tp_size="$((nnodes * num_dies / prefill_pp_size))"
    prefill_mem_fraction_static="$(get_prefill_mem_fraction_static "$prefill_tp_size")"
    readonly prefill_mem_fraction_static

}

[ "${pd_disaggregation_mode:-}" = "decode" ] && {
    decode_enable_cuda_graph() {
        true
    }
    decode_enable_deepep() {
        true
    }
    decode_enable_two_batch_overlap() {
        false
    }
    decode_enable_mock_balance() {
        false
    }
    decode_enable_profile() {
        false
    }
    readonly decode_tp_size="$((nnodes * num_dies))"
    readonly decode_dp_size="${decode_dp_size_default:-$decode_tp_size}"
    readonly decode_ep_size="${decode_ep_size_default:-$decode_tp_size}"
    readonly decode_pp_size="1"
    #readonly decode_tp_size="$decode_dp_size"
    readonly decode_max_running_requests="$decode_max_running_requests_default"
    readonly decode_mtp_num_draft_tokens="$decode_mtp_default"
    decode_eplb_file="${decode_eplb_file_specific:-}"
    decode_mem_fraction_static="$(get_decode_mem_fraction_static "$gpu_name" "$decode_dp_size" "$decode_mtp_num_draft_tokens" "$(is_not_empty "$decode_eplb_file")")"
    readonly decode_mem_fraction_static decode_eplb_file
}

prefill_decode_common_args=(
    "${prefill_decode_model_args[@]}"
    --model-path="$model_path"
    --context-length=${context_length_specific:-$((1024 * 129))}
    --dtype=auto
    --host="$local_ip"
    --watchdog-timeout=3600
    --trust-remote-code
    # --tokenizer-worker-num=4
    # --enable-metrics
    # --reasoning-parser=deepseek-r1
    # --tool-call-parser=deepseekv3
    # --chat-template="$script_dir/../sglang/examples/chat_template/tool_chat_template_deepseekv3.jinja"
    # --enable-single-batch-overlap
    # --json-model-override-args='{"index_topk_freq":2}'
)
# export SGLANG_DEEPEP_LL_COMBINE_SEND_NUM_SMS=20
# export USE_INDEX_CACHE=1

if [ "${nnodes:-1}" -gt 1 ]; then
   prefill_decode_common_args+=(
    --dist-init-addr="${master_node_ip:-}:${DIST_PORT:-5000}"
    --dist-timeout=30000
    --nnodes="${nnodes:-}"
    --node-rank="${node_rank:-}"
   )
fi

load_balance_method_shortest_queue() {
    false
}

enable_hierarchical_radix_cache() {
    [ "${MY_ENABLE_HICACHE:-0}" = "1" ]
}

enable_mooncake_store() {
    [ -n "${MY_TMUX_ENABLE_MOONCAKE_STORE:-}" ] && {
        [ "$MY_TMUX_ENABLE_MOONCAKE_STORE" -ne 0 ]
        return
    }
    false
}

prefill_decode_disaggregation() {
    [ -n "${MY_TMUX_PD_DISAGGREGATION:-}" ] && {
        [ "$MY_TMUX_PD_DISAGGREGATION" -ne 0 ]
        return
    }
    true
}

[ -n "${page_size:-}" ] && {
    prefill_decode_common_args+=(--page-size="$page_size")
    (( chunked_prefill_size % page_size == 0 )) || log_fatal "chunked_prefill_size($chunked_prefill_size) must be multiple of page_size($page_size)."
}

enable_mooncake_store && {
    # --hicache-storage-backend-extra-config
    export MOONCAKE_MASTER="$MY_MOONCAKE_MASTER_SERVER_IP:$mooncake_master_port"
    export MOONCAKE_TE_META_DATA_SERVER="http://$MY_MOONCAKE_META_DATA_SERVER_IP:$mooncake_metadata_port/metadata"
    export MOONCAKE_PROTOCOL="rdma"
    export MOONCAKE_DEVICE="$mooncake_ib_device"
    # L3 池总量 = **pp × 这个值**：sglang 每个进程只注册 `size // tp`
    # （mooncake_store.py:408 `per_tp_global_segment_size = global_segment_size // tp_size`），
    # 所以总量与 TP 无关、只随 PP 走 —— 我们 4 节点 pp4/tp8：4 GiB ⇒ 32 rank × 0.5 = **16 GiB**（实测
    # master_total_capacity_bytes=17179869184）；要 32 GiB（= 报告 §7 的量）就设 8gb。
    # ⚠️ 换节点数要同步改（pp8 时 4gb 仍是 32 GiB）。
    export MOONCAKE_GLOBAL_SEGMENT_SIZE="${MY_MOONCAKE_GLOBAL_SEGMENT_SIZE:-4gb}"
    export MOONCAKE_LOCAL_HOSTNAME="$local_ip"
    export MC_MS_AUTO_DISC=0


    # SGLANG_HICACHE_MOONCAKE_CONFIG_PATH = EnvStr(None)
    # MOONCAKE_CLIENT = EnvStr(None)
    # MOONCAKE_MASTER_METRICS_PORT = EnvInt(9003)
    # MOONCAKE_CHECK_SERVER = EnvBool(False)
    # MOONCAKE_STANDALONE_STORAGE = EnvBool(False)
    prefill_decode_common_args+=(
        # --enable-hierarchical-cache
        # --hicache-storage-backend mooncake
        # --hicache-storage-prefetch-policy timeout
        # --hicache-storage-backend-extra-config="$(json_compact '{
        #     "local_hostname": "$local_ip",
        # }')"
    )
}

prefill_decode_disaggregation && {
    prefill_decode_common_args+=(
        --disaggregation-ib-device="$mooncake_ib_device"
        --disaggregation-mode="${pd_disaggregation_mode:-}"
        --disaggregation-bootstrap-port=8998
    )
}

if load_balance_method_shortest_queue && prefill_decode_disaggregation; then
    prefill_decode_common_args+=(--load-balance-method=shortest_queue)
else
    prefill_decode_common_args+=(--load-balance-method=round_robin)
fi

# Python
export PYTHONFAULTHANDLER=1
export PYTHONUNBUFFERED=1

export MX_SGLANG_ENABLE_KV_LAYOUT_FIX=False

# SDK / Torch / Triton
export_multi_arch "CUDA_PATH" "/opt/maca/" "v"
export_multi_arch "CUDA_QUEUE_SCHEDULE_POLICY" "1"
export_multi_arch "CUDA_SMALL_PAGESIZE_ENABLE" "1"
# export_multi_arch "CUDA_GRAPH_HOST_NODE_MODE" "0"
# export_multi_arch "CUDA_LAUNCH_BLOCKING" "1"
export PYTORCH_ENABLE_PG_HIGH_PRIORITY_STREAM=1
export TRITON_ENABLE_ELEMENTWISE_PK_FMA_OPT=True
export_multi_arch "TRITON_DISABLE_CUDA_OPT_MMA_PREFETCH" "1"
export_multi_arch "TRITON_ENABLE_CUDA_CHAIN_DOT_OPT" "1"
export_multi_arch "TRITON_ENABLE_CUDA_COMPILER_INT8_OPT" "1"
export_multi_arch "TRITON_ENABLE_CUDA_OPT_MOVE_DOT_OPERANDS_OUT_LOOP" "1"
sdk_path_name="$(arch_str_map_cur_arch "CUDA_PATH")"
readonly sdk_path_name
path_prepend LD_LIBRARY_PATH "${!sdk_path_name}/$(arch_str_map_cur_arch "nvgdrcopy/lib")" "${!sdk_path_name}/$(arch_str_map_cur_arch "nvgpu_llvm/lib")"
[[ "|prefill|decode|" = *"|${pd_disaggregation_mode:-}|"* ]] && [ "$gpu_name" = "metax-c588" ] && {
    export_multi_arch "CUDA_VISIBLE_DEVICES" "0,1,2,3,6,5,4,7,10,9,8,11,14,15,12,13"
}
[[ "|prefill|decode|" = *"|${pd_disaggregation_mode:-}|"* ]] && [ "$gpu_name" = "metax-c600-al" ] && {
    export_multi_arch "CUDA_VISIBLE_DEVICES" "0,4,8,12,1,5,9,13,6,2,10,14,7,3,11,15"
}
[ "$sglang_version" = "v0.5.7" ]  || [ "$sglang_version" = "v0.5.8" ] || [ "$sglang_version" = "v0.5.12" ] || [ "$sglang_version" = "v0.5.13" ] && {
    export_multi_arch "CUDA_KERNEL_ARGS_POLICY" "0x010E"
    export_multi_arch "CUDA_RING_BUFFER_SIZE" "16384"
    export_multi_arch "TORCH_CUDA_ARCH_LIST" "8.0 8.6+PTX"
    export_multi_arch "CUDA_GRAPH_OPTIMIZE_POLICY" "0x1"
}

# 网络
export GLOO_SOCKET_IFNAME="$net_primary_iface"
export_multi_arch "NCCL_SOCKET_IFNAME" "$net_primary_iface"
export_multi_arch "NVSHMEM_BOOTSTRAP_UID_SOCK_IFNAME" "$net_primary_iface"
export_multi_arch "NVSHMEM_DISABLE_CUDA_VMM" "1"
export_multi_arch "NVSHMEM_SYMMETRIC_SIZE" "3g"
#export MXSHMEM_SYMMETRIC_SIZE=3g
# ⚠️ 名字必须是 SGLANG_DEEPEP_NUM_...（DEEPEP 后面有下划线）—— sglang 的 environ.py:563
#    定义的就是这个名字，默认 **128**。2026-09-21 实撞：原有写法 `SGLANG_DEEPEPNUM_...`
#    少一个下划线 ⇒ **静默失效**，实际用的是默认 128；而 deepep.py:723 的文档写着
#    "decode 引擎的实际 batch 应小于 256"，这个值同时决定 internode LL 派发缓冲的大小 ⇒
#    4 节点 decode 在 PD warmup 里崩在 `internode_ll::dispatch`，
#    驱动报 xnack(0x8)/ATU 地址翻译越界（缓冲被写爆）。
#    （本行与 decode.sh:32 读的是同一个名字，那边的拼写是对的。）
export SGLANG_DEEPEP_NUM_MAX_DISPATCH_TOKENS_PER_RANK=256
# export_multi_arch "NVMESH_USE_SDMA" "0" # 超节点: 0 XCore, 1 SDMA
[ -n "$hca_list" ] && {
    export_multi_arch "NCCL_IB_HCA" "$hca_list"
    export_multi_arch "NVSHMEM_HCA_LIST" "$hca_list"

    # ⚠️ 只在**单卡**时做 TC 查询：这段会顺带导出 NVSHMEM_IB_TRAFFIC_CLASS（DeepEP 的旋钮），
    #    与 Mooncake 无关。2026-09-21 把 mooncake_ib_device 改成可配置后，双口
    #    （mlx5_0,mlx5_1 == hca_list）会意外命中下面这个等值条件、把这条路径打开 ——
    #    而它此前一直是死代码。要启用 TC 请单独评估，别顺带打开。
    case "$mooncake_ib_device" in
    *,*) ;;
    *)
        [ "$mooncake_ib_device" = "$hca_list" ] && {
            traffic_class="$(get_hca_traffic_class "$hca_list")" || true
            if [ -n "$traffic_class" ]; then
                export_multi_arch "NVSHMEM_IB_TRAFFIC_CLASS" "$traffic_class"
            else
                log_warn "Failed to get traffic class for HCA '$mooncake_ib_device' from list '$hca_list'."
            fi
        }
        ;;
    esac
}
[[ "|prefill|decode|" = *"|${pd_disaggregation_mode:-}|"* ]] && {
    shmem_path="$(get_shmem_dir)"
    path_prepend LD_LIBRARY_PATH "$shmem_path/lib" "/usr/local/lib"
}

# SGLang
# export SGLANG_PROFILE_WITH_STACK=0
export SGLANG_DISAGGREGATION_QUEUE_SIZE=8
export SGLANG_DISAGGREGATION_THREAD_POOL_SIZE=24
export SGL_DISABLE_TP_MEMORY_INBALANCE_CHECK=1
[ "$sglang_version" = "v0.5.7" ] && {
    export SGLANG_DEEPEP_BF16_DISPATCH=1
    export SGLANG_JIT_DEEPGEMM_PRECOMPILE=0
    export SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1
    export USE_SINGLE_STREAM_DISPATCH_OVERLAP=1
}

#[ "$sglang_version" = "v0.5.8" ] && {
    #export SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1
#    export USE_SINGLE_STREAM_DISPATCH_OVERLAP=1
#    export USE_SINGLE_STREAM=1
#}
# export SGLANG_DEBUG_TTFT=1
# export SGLANG_DISAGGREGATION_WAITING_TIMEOUT=100

path_prepend LD_LIBRARY_PATH "/usr/local/lib"
export CUDA_PATH=/opt/maca/tools/cu-bridge
export MCCL_RING_BUFFER_SIZE=4096
