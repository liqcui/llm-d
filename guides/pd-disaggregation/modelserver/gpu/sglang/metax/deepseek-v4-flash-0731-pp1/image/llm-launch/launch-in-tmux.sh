#!/bin/bash
# 功能: 在 tmux 会话中远程启动多个容器并运行指定命令, 将手动操作自动化
#

set -euE
shopt -s inherit_errexit

script_file="$(realpath -se "$0")"
script_dir="$(cd "$(dirname "$script_file")" && pwd)"
readonly script_file script_dir

# shellcheck source=./utils/error.sh
source "$script_dir/utils/error.sh"
# shellcheck source=./utils/utils.sh
source "$script_dir/utils/utils.sh"

version_le 4.4 "${BASH_VERSINFO[0]}"."${BASH_VERSINFO[1]}" || log_fatal "Bash version >= 4.4 is required. Current version: $BASH_VERSION"

usage() {
    local -r l_script="$(basename "$0")"
    echo "Usage: $l_script sglang|vllm <model spec> [kill|clean|rm-container|wait]" >&2
    echo "       $l_script sglang|vllm kill|clean|rm-container" >&2
    echo "       $l_script deepep [kill|clean|rm-container|wait]" >&2
    exit 1
}

[ "$#" -ge 1 ] || usage

readonly backend="$1"
action="${!#}"
if [[ "|sglang|vllm|" = *"|$backend|"* ]]; then
    [ "$#" -ge 2 ] || usage
elif [[ "$backend" = "deepep" ]]; then
    true
else
    usage
fi;
if [[ "|kill|clean|rm-container|wait|" = *"|$action|"* ]]; then
    arg_passthrough_params=("${@:2:$#-2}")
else
    action=""
    arg_passthrough_params=("${@:2}")
fi
readonly action
readonly -a arg_passthrough_params
if [ "${#arg_passthrough_params[@]}" -gt 0 ]; then
    printf -v passthrough_params "%q " "${arg_passthrough_params[@]}"
    passthrough_params="${passthrough_params% }"
else
    passthrough_params=""
fi
readonly passthrough_params

[ -f "$script_dir/$backend/tmux-config.sh" ] || log_fatal "Config file for backend '$backend' not found: $script_dir/$backend/tmux-config.sh"

if [ "$backend" = "sglang" ]; then
    readonly key_task_server_ready="The server is fired up and ready to roll!"
    readonly key_minilb_ready=" Uvicorn running on \| Successfully registered tokenize "
    readonly key_store_ready="Master service started on port"
elif [ "$backend" = "vllm" ]; then
    readonly key_task_server_ready="Application startup complete."
    readonly key_minilb_ready=" Uvicorn running on "
elif [ "$backend" = "deepep" ]; then
    readonly key_task_server_ready="Allocating buffer size\|\[tuning\]\|\[rank 0\] Dispatch"
    readonly key_minilb_ready=" Uvicorn running on \| Successfully registered tokenize "
else
    log_fatal "Unsupported backend: $backend"
fi

# shellcheck source=./sglang/tmux-config.sh
source "$script_dir/$backend/tmux-config.sh"

readonly log_write_location="remote" # container, remote, host

check_commands tmux

readonly nodes_start_idx=2
task_get_id() {
    local -n l_task_ref="$1"
    echo "${l_task_ref[0]}"
}
task_get_script() {
    local -n l_task_ref="$1"
    echo "${l_task_ref[1]}"
}
task_get_num_nodes() {
    local -n l_task_ref="$1"
    echo "$((${#l_task_ref[@]} - nodes_start_idx))"
}
task_get_node() {
    local -n l_task_ref="$1"
    local l_node_idx="$2"
    echo "${l_task_ref[$((nodes_start_idx + l_node_idx))]}"
}
task_get_nodes() {
    local -n l_task_ref="$1"
    printf "%s\n" "${l_task_ref[@]:$nodes_start_idx}"
}

tmux_pane_current_command() {
    local -r l_pane_id="$1"
    tmux display-message -t "$l_pane_id" -p "#{pane_current_command}"
}

tmux_has_pane() {
    local -r l_pane_id="$1"
    tmux has-session -t "$l_pane_id" 2>/dev/null
}

tmux_is_idle() {
    local -r l_pane_id="$1"
    tmux display-message -p -t "$l_pane_id" '#{pane_pid}' | xargs -I{} ps -o stat= -p {} | grep -q "+$"
}

kill_and_wait() {
    local -r l_pane_id="$1"
    local -r l_interval="${2:-1}"
    local -r l_echo_message="#### the current shell is idle"
    local l_last_screen l_ssh_idle
    while tmux_has_pane "$l_pane_id" && ! tmux_is_idle "$l_pane_id"; do
        tmux send-keys -t "$l_pane_id" C-c C-m
        sleep "$l_interval"
        if [ "$(tmux_pane_current_command "$l_pane_id")" = "ssh" ]; then
            l_last_screen="$(tmux capture-pane -p -t "$l_pane_id" | grep -vP '^\s*$')"
            l_ssh_idle=0
            if [ "$(echo "$l_last_screen" | tail -1 | cut -d@ -f1)" = "$USER" ]; then
                l_ssh_idle=1
            elif echo "$l_last_screen" | grep -q "^$l_echo_message"; then
                l_ssh_idle=1
            elif [ "$(echo "$l_last_screen" | grep -c .)" -gt 10 ] && [ "$(echo "$l_last_screen" | cut -d'^' -f1 | xargs -n1 | sort -u | grep -c .)" -le 2 ]; then
                l_ssh_idle=1
            else
                tmux send-keys -t "$l_pane_id" "echo '$l_echo_message'" C-m
            fi
            [ "$l_ssh_idle" -ne 0 ] && {
                tmux send-keys -t "$l_pane_id" "exit" C-m
                sleep "$l_interval"
            }
        fi
    done
    true
}

kill_process() {
    tmux has-session -t "$task_session_name" 2>/dev/null || return 0
    echo "Cleaning $task_session_name ..."
    local -r l_win_ids="$(tmux list-windows -t "$task_session_name" | grep -oP '^\d+')"
    local l_win_id
    for l_win_id in $l_win_ids; do
        ! tmux_is_idle "$task_session_name:$l_win_id" && tmux send-keys -t "$task_session_name:$l_win_id" C-c C-m
    done
    for l_win_id in $l_win_ids; do
        echo "Terminating $task_session_name:$l_win_id($(tmux display-message -t "$task_session_name:$l_win_id" -p "#W")) ..."
        kill_and_wait "$task_session_name:$l_win_id" 1
    done
    true
}

cleanup_session() {
    tmux kill-session -t "=$task_session_name" 2>/dev/null || true
}

discover_tasks() {
    declare -p | grep -oP '(?<=^declare -ar )task_[^=]+' | sort
}
readarray -t all_tasks < <(discover_tasks)
readonly all_tasks
enable_pd_disaggregation="$([ "$(printf "%s\n" "${all_tasks[@]}" | cut -d_ -f2 | sort -u | paste -sd,)" = "decode,prefill" ] && echo 1 || echo 0)"
readonly enable_pd_disaggregation
[ "$enable_pd_disaggregation" -ne 0 ] && {
    [ -n "${node_minilb:-}" ] || log_fatal "PD disaggregation is enabled but node_minilb is not set in the tmux config"
}

get_all_task_nodes() {
    local -a l_all_nodes=()
    local l_task
    local -a l_nodes
    for l_task in "${all_tasks[@]}"; do
        readarray -t l_nodes < <(task_get_nodes "$l_task")
        l_all_nodes+=("${l_nodes[@]}")
    done
    printf "%s\n" "${l_all_nodes[@]}" | grep -vP '^\s*$' | sort -u
}
readarray -t all_task_nodes < <(get_all_task_nodes)
readonly all_task_nodes

rm_all_container_helper() {
    local -r l_device="$1"
    local -r l_engine="$2"
    local -r l_container_name="$3"
    timeout 60 ssh -o ConnectTimeout=1 "$l_device" "
        set -euE
        $l_engine ps | grep '$l_container_name' >/dev/null && {
            $l_engine stop -t 5 '$l_container_name' >/dev/null || $l_engine kill '$l_container_name' || true
        }
        $l_engine ps -a | grep '$l_container_name' >/dev/null && $l_engine rm -f '$l_container_name' >/dev/null
        true
    " || { log_error "Failed to remove container '$l_container_name' on device '$l_device'"; kill -SIGTERM 0; }
}

rm_all_container() {
    echo "Removing all containers named '$container_name' on all nodes ..."
    local -a l_all_nodes=(
        "${node_client:-}"
        "${node_minilb:-}"
        "${node_store:-}"
        "${all_task_nodes[@]}"
    )
    readarray -t l_all_nodes < <(printf "%s\n" "${l_all_nodes[@]}" | grep -vP '^\s*$' | sort -u)
    local l_node
    for l_node in "${l_all_nodes[@]}"; do
        rm_all_container_helper "$l_node" "$container_engine" "$container_name" &
    done
    wait
    true
}

[[ "|kill|clean|rm-container|" = *"|$action|"* ]] && {
    kill_process
    [ "$action" = "clean" ] && cleanup_session
    [ "$action" = "rm-container" ] && rm_all_container
    exit 0
}

check_gpu_idle() {
    echo "Checking if GPUs on all task nodes are idle ..."
    local l_i l_check_res l_num_process
    local -r l_limit=3
    for l_i in $(seq "$l_limit"); do
        l_check_res="$("$script_dir/utils/check-devices.sh" process <(printf "%s\n" "${all_task_nodes[@]}") 2>&1)" || log_fatal "$(echo -e "Failed to check GPU process status:\n$l_check_res")"
        l_num_process="$(echo "$l_check_res" | awk -F'[,:]' '/process:/ { sum += $5 } END { print sum+0 }')"
        [ "$l_num_process" -eq 0 ] && return 0
        sleep 2
    done
    log_fatal "$(echo -e "Some processes are still running on the GPUs:\n$l_check_res")"
}

tmux_new_session_if_not_exists() {
    local -r l_session_name="$1"
    local -r l_window_name="$2"
    tmux has-session -t "$l_session_name" 2>/dev/null && return 0
    tmux new-session -s "$l_session_name" -n "$l_window_name" -c "$HOME" -d
}

script_tty="$(tty)" || log_fatal "Failed to get current TTY, are you running in a valid terminal?"
readonly script_tty
tmux list-panes -a -F '#{pane_tty}' 2>/dev/null | grep -q "^$script_tty$" || {
    # 在非 tmux 环境下直接运行脚本，自动创建一个 tmux 会话并在其中运行脚本
    readonly llm_launch_default_session="llm-launch-default"
    readonly llm_launch_default_window="main"
    log_warn "Not in tmux, creating new session '$llm_launch_default_session' and running the script inside it..."
    tmux_new_session_if_not_exists "$llm_launch_default_session" "$llm_launch_default_window"
    readonly target_pane="$llm_launch_default_session:$llm_launch_default_window"
    tmux send-keys -t "$target_pane" C-a C-k "cd '$script_dir' && './$(basename "$script_file")' ${*@Q}" C-m
    tmux attach-session -t "$target_pane"
    exit 0
}

tmux_current_session_name() {
    local l_session_name
    l_session_name="$(tmux list-panes -a -F '#{pane_tty},#{session_name}' | awk -F, -v tty="$script_tty" '$1 == tty { print $2 }' | sort -u)"
    [ "$(echo "$l_session_name" | grep -c .)" -eq 1 ] || log_fatal "Failed to determine current tmux session name from: $l_session_name"
    echo "$l_session_name"
}

tmux_switch_client() {
    local -r l_target="$1"
    local -r l_flag="${2:-}"
    local l_switch=0
    [ "$l_flag" = "force" ] && [ "$(tmux display-message -p '#{session_attached}')" -gt 0 ] && l_switch=1
    [ "$l_switch" -eq 0 ] && [ "$(tmux display-message -t "$task_session_name" -p '#{session_attached}')" -gt 0 ] && l_switch=1
    [ "$l_switch" -ne 0 ] && tmux switch-client -t "$l_target"
}

[ "$(tmux_current_session_name)" = "$task_session_name" ] && {
    log_warn "Detected execution inside the task tmux session. Switching back to the original llm-launch pane to continue..."
    [ -n "${LLM_LAUNCH_PANE_ID:-}" ] || {
        log_fatal "LLM_LAUNCH_PANE_ID is not set in the task tmux session. Please rerun the script from the original llm-launch pane."
    }
    tmux send-keys -t "$LLM_LAUNCH_PANE_ID" C-a C-k "sleep 1 && cd '$script_dir' && './$(basename "$script_file")' ${*@Q}" C-m
    tmux_switch_client "$LLM_LAUNCH_PANE_ID" "force" || true
    exit 0
}

ip_resolve_ssh() {
    ssh -G "$1" | grep -oP '(?<=hostname )\d+(\.\d+){3}'
}

get_window_name() {
    local -r l_task_id="$1"
    local -r l_task_rank="$2"
    [ -n "${l_task_id:-}" ] || log_fatal "task_id is required"
    echo "${l_task_id}${l_task_rank:+-node-$l_task_rank}"
}

get_pane_id() {
    local -r l_task_id="$1"
    local -r l_task_rank="${2:-}"
    echo "$task_session_name:$(get_window_name "$l_task_id" "$l_task_rank")"
}

tmux_current_pane_id() {
    local l_pane_id
    l_pane_id="$(tmux list-panes -a -F '#{pane_tty},#{pane_id}' | awk -F, -v tty="$script_tty" '$1 == tty { print $2 }')"
    [ -n "$l_pane_id" ] || log_fatal "Failed to determine current tmux pane ID"
    echo "$l_pane_id"
}

llm_launch_pane_id="$(tmux_current_pane_id)"
readonly llm_launch_pane_id
tmux_ensure_window() {
    local -r l_window_name="$1"
    if ! tmux has-session -t "$task_session_name" 2>/dev/null; then
        tmux new-session -s "$task_session_name" -n "$l_window_name" -c "$HOME" -d
    elif ! tmux has-session -t "$task_session_name:$l_window_name" 2>/dev/null; then
        tmux new-window -t "$task_session_name" -n "$l_window_name"
    fi
    [ -n "${llm_launch_pane_id:-}" ] && {
        local l_pane_id="$task_session_name:$l_window_name"
        # 用户格式化 time 的输出
        tmux send-keys -t "$l_pane_id" 'export TIMEFORMAT="%Rs total %Us user %Ss system %P%% cpu"' C-m
        # 用于在自动创建的窗口里执行命令时自动跳回
        tmux send-keys -t "$l_pane_id" "export LLM_LAUNCH_PANE_ID='$llm_launch_pane_id'" C-m
        # 用于在自动创建的窗口和启动窗口之间来回切换
        local l_a l_b l_c
        # 在 llm_launch 的 alias 里执行
        l_a="tmux switch-client -t $(printf "%q" "$l_pane_id")"
        # 在 llm_launch 里执行o
        l_b="alias t=$(printf "%q" "$l_a")"
        # 在 task 的 alias 里执行
        local l_pane_id_escape
        l_pane_id_escape="$(printf "%q" "$llm_launch_pane_id")"
        l_c="tmux send-key -t $l_pane_id_escape C-a C-k $(printf "%q" "$l_b") C-m; tmux switch-client -t $l_pane_id_escape"
        tmux send-keys -t "$l_pane_id" "alias t=${l_c@Q}" C-m
    }
    true
}

fail_and_switch() {
    local -r l_pane_id="$1"
    local -r l_err_msg="$2"
    [ "$action" = "wait" ] && tmux_switch_client "$llm_launch_pane_id" && {
        tmux send-key -t "$llm_launch_pane_id" C-a C-k "alias t='tmux switch-client -t $l_pane_id'" C-m
    }
    log_fatal "$l_err_msg"
}

wait_server_ready() {
    local -r l_pane_id="$1"
    local -r l_search_text="$2"
    local -r l_interval="${3:-1}"
    echo "Waiting ${l_pane_id#*:} '$l_search_text' ..."
    tmux select-window -t "$l_pane_id"

    local l_screen_last=""
    local l_screen=""
    local l_screen_same_time
    l_screen_same_time="$(date +%s)"
    local l_ready=0
    while :; do
        l_screen="$(tmux capture-pane -p -t "$l_pane_id")"
        echo "$l_screen" | grep -q "$l_search_text" && l_ready=1 && break # 服务启动好了
        echo "$l_screen" | grep -q "ValueError: TP rank " && break
        tmux_is_idle "$l_pane_id" && break

        if [ "$l_screen" != "$l_screen_last" ]; then
            l_screen_last="$l_screen"
            l_screen_same_time="$(date +%s)"
        elif [ "$(( $(date +%s) - l_screen_same_time ))" -ge 600 ]; then
            fail_and_switch "$l_pane_id" "No output change in ${l_pane_id#*:} for 10 minutes while waiting for '$l_search_text'"
        fi
        sleep "$l_interval"
    done
    [ "$l_ready" -ne 0 ] || {
        fail_and_switch "$l_pane_id" "Failed to detect '$l_search_text' in ${l_pane_id#*:}"
    }
    true
}

wait_shell_idle() {
    local -r l_pane_id="$1"
    local -r l_interval="${2:-1}"
    local -r l_finish_signal="${3:-}"
    while ! tmux_is_idle "$l_pane_id"; do
        if [ -n "$l_finish_signal" ]; then
            timeout "$l_interval" tmux wait-for "$l_finish_signal" && break
        else
            sleep "$l_interval"
        fi
    done
    true
}

env_vars() {
    [ $# -gt 0 ] || return 0
    printf "env "
    printf "%q " "$@" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

readonly signal_name_client_finished="client_finished"
timestamp="$(date +%s)"
readonly timestamp
timezone="$(date +"%z" -d "@$timestamp")"
readonly timezone="${timezone%00}"
profile_dir_prefix="${my_service_profile_base_dir:-1}/$(date +"%y%m/%d/%y%m%d-%H%M%S$timezone" -d "@$timestamp")"
readonly profile_dir_prefix
readonly prefill_profile_dir="$profile_dir_prefix-prefill"
readonly decode_profile_dir="$profile_dir_prefix-decode"
tmux_run_remote_cmd() {
    local -r l_task_id="$1"
    local -r l_task_rank="$2"
    local -r l_remote_node="$3"
    local -r l_cmd="$4"
    local -r l_dry_run="${5:-}"
    local l_container_env_vars=("TQDM_NCOLS=120")
    local l_is_prefill_or_decode=0
    local l_task_kind
    l_task_kind="$(echo "$l_task_id" | grep -oP '^\w+')"
    if [ "$l_task_kind" = "prefill" ]; then
        l_is_prefill_or_decode=1
        l_container_env_vars+=("MY_SERVICE_TORCH_PROFILER_DIR_PREFILL=$prefill_profile_dir")
    elif [ "$l_task_kind" = "decode" ]; then
        l_is_prefill_or_decode=1
        l_container_env_vars+=("MY_SERVICE_TORCH_PROFILER_DIR_DECODE=$decode_profile_dir")
    fi
    [ "$l_is_prefill_or_decode" -ne 0 ] && {
        local -r l_enable_mooncake_store="$([ -n "${node_store:-}" ] && echo 1 || echo 0)"
        l_container_env_vars+=(
            "MY_TMUX_PD_DISAGGREGATION=$enable_pd_disaggregation"
            "MY_TMUX_ENABLE_MOONCAKE_STORE=$l_enable_mooncake_store"
        )
        [ "$l_enable_mooncake_store" -ne 0 ] && {
            local -r l_node_store_ip="$(ip_resolve_ssh "$node_store")"
            l_container_env_vars+=(
                "MY_MOONCAKE_MASTER_SERVER_IP=$l_node_store_ip"
                "MY_MOONCAKE_META_DATA_SERVER_IP=$l_node_store_ip"
            )
        }
    }

    local -a l_log_env_vars=(
        "MY_LOG_TIMESTAMP_S=$timestamp"
        "MY_LOG_PROGRAM_NAME=$l_task_kind"
        "MY_LOG_FILE_ID=$l_task_id"
        "MY_LOG_USE_EXACT_TIMESTAMP_DIR=1"
        "MY_LOG_GROUP_BY_TIMESTAMP=1"
    )
    [ -n "${l_task_rank:-}" ] && l_log_env_vars+=("MY_LOG_PROGRAM_RANK=$l_task_rank")
    [ -n "${my_log_base_dir:-}" ] && l_log_env_vars+=("MY_LOG_BASE_DIR=$my_log_base_dir")

    local -a l_remote_env_vars=("MY_CONTAINER_REUSE=1")
    local l_image="${image:-}"
    local l_image_ref="image_$l_task_kind"
    [ -n "${!l_image_ref:-}" ] && l_image="${!l_image_ref}"
    [ -n "${l_image:-}" ] && l_remote_env_vars+=("MY_CONTAINER_IMAGE=$l_image")
    local l_image_name="${image_name:-}"
    local l_image_name_ref="image_name_$l_task_kind"
    [ -n "${!l_image_name_ref:-}" ] && l_image_name="${!l_image_name_ref}"
    [ -n "${l_image_name:-}" ] && l_remote_env_vars+=("MY_CONTAINER_IMAGE_NAME=$l_image_name")
    [ -n "${container_name:-}" ] && l_remote_env_vars+=("MY_CONTAINER_NAME=$container_name")
    [ -n "${container_engine:-}" ] && l_remote_env_vars+=("MY_CONTAINER_ENGINE=$container_engine")
    [ -z "$l_image" ] && [[ "|client|minilb|" = *"|$l_task_kind|"* ]] && l_remote_env_vars+=("MY_CONTAINER_CHECK_CONTAINER_MATCH=0")

    local l_cmd_log
    l_cmd_log="$(env_vars "${l_log_env_vars[@]}") ../utils/launch-and-log.sh"
    if [ "$log_write_location" = "container" ]; then
        local l_container_log="$l_cmd_log"
    elif [ "$log_write_location" = "remote" ]; then
        local l_remote_log="$l_cmd_log"
    elif [ "$log_write_location" = "host" ]; then
        local l_host_log="$l_cmd_log"
    elif [ -z "$log_write_location" ]; then
        true
    else
        log_fatal "Invalid log_write_location: $log_write_location"
    fi

    local l_sig_finished=""
    [ "$l_task_id" = "client" ] && l_sig_finished="; tmux wait-for -S $signal_name_client_finished"

    local -r l_cmd_container="set -x; cd $(printf "%q" "$container_script_dir/$backend") && ${l_container_log:-} $(env_vars "${l_container_env_vars[@]}") $l_cmd"
    local -r l_cmd_remote="cd $(printf "%q" "$script_dir/$backend") && ${l_remote_log:-} $(env_vars "${l_remote_env_vars[@]}") ../utils/launch-on-host.sh bash -c $(printf "%q" "$l_cmd_container")"
    local -r l_cmd_tmux="(clear && cd $(printf "%q" "$script_dir/$backend") && time ${l_host_log:-} ssh -t $l_remote_node ${l_cmd_remote@Q}; ec=\$?; date$l_sig_finished; exit \$ec) # $l_cmd_container"
    local -r l_pane_id="$(get_pane_id "$l_task_id" "$l_task_rank")"
    [ -n "$l_dry_run" ] && tmux select-pane -t "$l_pane_id" -T "ssh $l_remote_node"
    tmux send-keys -t "$l_pane_id" C-a C-k "$l_cmd_tmux"
    [ -z "$l_dry_run" ] && tmux send-keys -t "$l_pane_id" C-m
    true
}

setup_windows() {
    local -ar l_tasks=("$@")
    [ -n "${node_client:-}" ] && tmux_ensure_window "client"
    [ "$enable_pd_disaggregation" -ne 0 ] && [ -n "${node_minilb:-}" ] && tmux_ensure_window "minilb"
    local l_task_name
    local -i l_num_nodes l_task_rank
    for l_task_name in "${l_tasks[@]}"; do
        l_num_nodes="$(task_get_num_nodes "$l_task_name")"
        for ((l_task_rank=0; l_task_rank < l_num_nodes; l_task_rank++)); do
            tmux_ensure_window "$(get_window_name "$(task_get_id "$l_task_name")" "$l_task_rank")"
        done
    done
    [ -n "${node_store:-}" ] && tmux_ensure_window "store"
    sleep 0.5
    true
}

run_tasks() {
    if [ "${*: -1}" = "dry-run" ]; then
        local -ar l_tasks=("${@:1:$#-1}")
        local -r l_dry_run="dry-run"
    else
        local -ar l_tasks=("$@")
        local -r l_dry_run=""
    fi
    tmux_switch_client "$task_session_name" "force" || true
    # Mooncake Store
    [ -n "${node_store:-}" ] && {
        tmux_run_remote_cmd "store" "" "$node_store" "bash ./store.sh" "$l_dry_run"
        [ -z "$l_dry_run" ] && wait_server_ready "$(get_pane_id "store")" "$key_store_ready"
    }

    # Run prefill and decode
    local l_server_ip="" l_task_name l_task_id l_task_script l_master_ip l_cmd l_node
    local -i l_num_nodes l_task_rank l_wait_interval
    local -a l_prefill_ips=() l_decode_ips=()
    for l_task_name in "${l_tasks[@]}"; do
        l_task_id="$(task_get_id "$l_task_name")"
        l_task_script="$(task_get_script "$l_task_name")"
        l_master_ip="$(ip_resolve_ssh "$(task_get_node "$l_task_name" 0)")"
        [ -z "$l_server_ip" ] && l_server_ip="$l_master_ip:$(echo "$l_task_id" | grep -oP '^\w+')"
        l_num_nodes="$(task_get_num_nodes "$l_task_name")"
        l_cmd="bash $(printf "%q" "$l_task_script") $passthrough_params $(printf "%q" "$l_master_ip") $(printf "%q" "$l_num_nodes")"
        for ((l_task_rank=0; l_task_rank < l_num_nodes; l_task_rank++)); do
            l_node="$(task_get_node "$l_task_name" "$l_task_rank")"
            tmux_run_remote_cmd "$l_task_id" "$l_task_rank" "$l_node" "$l_cmd $(printf "%q" "$l_task_rank")" "$l_dry_run"
        done
    done

    for l_task_name in "${l_tasks[@]}"; do
        l_task_id="$(task_get_id "$l_task_name")"
        l_wait_interval=3
        [[ "$l_task_id" = "deepep"* ]] && l_wait_interval=1
        [ -z "$l_dry_run" ] && wait_server_ready "$(get_pane_id "$l_task_id" 0)" "$key_task_server_ready" "$l_wait_interval"
        l_master_ip="$(ip_resolve_ssh "$(task_get_node "$l_task_name" 0)")"
        if [[ "$l_task_id" = "prefill"* ]]; then
            l_prefill_ips+=("$l_master_ip")
        elif [[ "$l_task_id" = "decode"* ]]; then
            l_decode_ips+=("$l_master_ip")
        fi
    done

    # Minilb
    [ "$enable_pd_disaggregation" -ne 0 ] && [ -n "${node_minilb:-}" ] && {
        l_server_ip="$(ip_resolve_ssh "$node_minilb"):minilb"
        tmux_run_remote_cmd "minilb" "" "$node_minilb" "bash ./minilb.sh prefill $(printf "%q " "${l_prefill_ips[@]}") decode $(printf "%q " "${l_decode_ips[@]}")" "$l_dry_run"
        [ -z "$l_dry_run" ] && wait_server_ready "$(get_pane_id "minilb")" "$key_minilb_ready"
    }

    # Client
    [ -n "${node_client:-}" ] && {
        tmux_run_remote_cmd "client" "" "$node_client" "bash ./client.sh $passthrough_params $(printf "%q" "$l_server_ip")" "$l_dry_run"
        [ -z "$l_dry_run" ] && tmux select-window -t "$(get_pane_id "client")"
    }
    true
}

cd "$script_dir" || log_fatal "Failed to change directory to script_dir: $script_dir"

kill_process
cleanup_session
rm_all_container
check_gpu_idle

setup_windows "${all_tasks[@]}"
run_tasks "${all_tasks[@]}" "dry-run"
run_tasks "${all_tasks[@]}"

[ "$action" = "wait" ] && {
    echo "Waiting for tasks to complete..."
    wait_shell_idle "$task_session_name:0" 60 "$signal_name_client_finished"
    tmux_switch_client "$llm_launch_pane_id" || true
}
true
