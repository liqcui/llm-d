#!/bin/bash
# 功能: 在指定位置记录日志并运行指定命令
# Usage: ./launch-and-log.sh <command to run...>
# 可配置的环境变量参数:
#   MY_LOG_BASE_DIR: 日志存放的基础目录, 这个目录必须存在, 不会自动创建
#   MY_LOG_FILE_ID: 日志文件标识符, 默认为程序名称, 可用来区分同时运行的多个 prefill 实例
#   MY_LOG_PROGRAM_NAME: 程序名称, 默认为命令的第一个参数的文件名部分, 是日志最后一个文件夹名称的一部分，
#   MY_LOG_PROGRAM_RANK: 默认为空, 如果设置了则会添加到日志文件名中, 用于将同一个服务的日志写到一个目录
#   MY_LOG_TIMESTAMP_S: 指定时间戳, 默认为当前时间, 用于日志目录和文件命名
#   MY_LOG_USE_EXACT_TIMESTAMP_DIR: 总是使用指定时间戳访问目录, 如果配置为 1, 需配置 MY_LOG_TIMESTAMP_S
#   MY_LOG_GROUP_BY_TIMESTAMP: 按时间戳创建父目录，并将程序日志目录放到父目录下

set -euE
shopt -s inherit_errexit
trap 'echo "Script failed at line $LINENO. Command: [$BASH_COMMAND] (Exit status: $?)"' ERR

[ "$#" -eq 0 ] && {
    echo "Usage: $0 <command to run...>"
    exit 1
}

log_base_dir_env="${MY_LOG_BASE_DIR:-}"
log_file_id_env="${MY_LOG_FILE_ID:-}"
program_name_env="${MY_LOG_PROGRAM_NAME:-}"
program_rank_env="${MY_LOG_PROGRAM_RANK:-}"
program_rank="${program_rank_env:-0}"
timestamp_s_env="${MY_LOG_TIMESTAMP_S:-}"
use_exact_timestamp_dir="${MY_LOG_USE_EXACT_TIMESTAMP_DIR:-0}"
group_by_timestamp="${MY_LOG_GROUP_BY_TIMESTAMP:-0}"
readonly log_base_dir_env log_file_id_env program_name_env program_rank_env program_rank timestamp_s_env use_exact_timestamp_dir group_by_timestamp

if [ -z "$timestamp_s_env" ] && [[ "$program_rank" -ne 0 ]] && [[ "$use_exact_timestamp_dir" -ne 0 ]]; then
    echo "Error: When MY_LOG_PROGRAM_RANK is set and MY_LOG_USE_EXACT_TIMESTAMP_DIR is 1, MY_LOG_TIMESTAMP_S must be set." >&2
    exit 1
fi

timestamp="${timestamp_s_env:-$(date +%s)}"
readonly timestamp

[ -n "$log_base_dir_env" ] && mkdir -p "$log_base_dir_env"

readonly cond_log_base_dirs=(
    "$log_base_dir_env"
    "/mnt/storage/deepseek-pd/log"
)
log_base_dir=""
for dir in "${cond_log_base_dirs[@]}"; do
    [ -n "$dir" ] && [ -d "$dir" ] && {
        log_base_dir="$dir"
        break
    }
done
[ -n "$log_base_dir" ] || {
    echo "No valid log directory found."
    exit 1
}
readonly log_base_dir

local_ip="$(ip route get 8.8.8.8 | grep -oP '(?<=src )\d+(\.\d+){3}')"
readonly local_ip

link_latest() {
    local l_base_dir="$1"
    local l_target_dir="$2"
    l_base_dir="$(realpath -e "$l_base_dir")"
    l_target_dir="$(realpath -e "$l_target_dir")"

    if [[ "$l_target_dir" != "$l_base_dir"/* ]]; then
        echo "Error: Target dir '$l_target_dir' must be a subdirectory of base dir '$l_base_dir'" >&2
        return 1
    fi

    local l_cur_dir="$l_base_dir"
    local l_rel_path="${l_target_dir#"$l_base_dir/"}"

    while [[ -n "$l_rel_path" ]]; do
        local next_segment="${l_rel_path%%/*}"
        ln -nfs "$next_segment" "$l_cur_dir/latest"

        l_cur_dir="$l_cur_dir/$next_segment"
        if [[ "$l_rel_path" == *"/"* ]]; then
            l_rel_path="${l_rel_path#*/}"
        else
            l_rel_path=""
        fi
    done
}

program_name="${program_name_env:-$(basename "$1")}"
program_name="$(echo -n "${program_name%.*}" | tr -sc '[:alnum:]' -)"
log_file_id="${log_file_id_env:-$program_name}"
log_file_id="$(echo -n "$log_file_id" | tr -sc '[:alnum:]' -)"
readonly program_name log_file_id

timezone="$(date +"%z" -d "@$timestamp")"
readonly timezone="${timezone%00}"
log_timestamp_path="$(date +"%y%m/%d/%H%M%S$timezone" -d "@$timestamp")"
if [[ "$group_by_timestamp" -ne 0 ]]; then
    log_dir_rel_path="$log_timestamp_path/$program_name"
else
    log_dir_rel_path="$log_timestamp_path-$program_name"
fi
readonly log_dir_rel_path

if [[ "$program_rank" -eq 0 ]] || [[ "$use_exact_timestamp_dir" -ne 0 ]]; then
    # rank 0 负责创建带时间戳的日志目录，并刷新各级 latest 链接。
    log_dir="$log_base_dir/$log_dir_rel_path"
    mkdir -p "$log_dir"
    link_latest "$log_base_dir" "$(dirname "$log_dir")"
    if [[ "$group_by_timestamp" -eq 0 ]]; then
        ln -nfs "$(basename "$log_dir")" "$(dirname "$log_dir")/latest-$program_name"
    fi
else
    # 其他 rank 通过 latest 链接复用 rank 0 已创建的同一日志目录。
    latest_parent_dir="$log_base_dir/$(dirname "$log_dir_rel_path" | sed -E 's|[^/]+|latest|g')"
    if [[ "$group_by_timestamp" -ne 0 ]]; then
        log_dir="$(realpath -e "$latest_parent_dir/$program_name")"
    else
        log_dir="$(realpath -e "$latest_parent_dir/latest-$program_name")"
    fi
fi
log_file="$log_dir/log-$log_file_id${program_rank_env:+-$(printf "%02d" "$program_rank")}-$(date +"%y%m%d-%H%M%S-%3N")-$local_ip.txt"
readonly log_dir log_file

# 通过手动创建管道来过滤日志，自动的有时会死锁无法自动退出
log_fifo_dir="$(mktemp -d)"
log_fifo="$log_fifo_dir/launch-and-log.fifo"
readonly log_fifo_dir log_fifo

# shellcheck disable=SC2329
cleanup_log_fifo() {
    rm -rf "$log_fifo_dir"
}
trap cleanup_log_fifo EXIT

mkfifo "$log_fifo"

env LC_ALL=C stdbuf -oL -eL sed -E 's/\x1b\[[0-9;?]*[A-Za-z]//g; s/\r$//; s/.*\r//; s/[ \t]+$//; :a; s/[^\x08]\x08//g; ta; s/[\x08\x01]//g' < "$log_fifo" > "$log_file" &
log_writer_pid="$!"
readonly log_writer_pid

echo "log file: $log_file"
stdbuf -oL -eL "$@" 2>&1 | tee "$log_fifo"
pipeline_status=("${PIPESTATUS[@]}")

wait "$log_writer_pid"
log_writer_status="$?"
[ "$log_writer_status" -eq 0 ] || echo "Log writer exited with status $log_writer_status" >&2

exit "${pipeline_status[0]}"
