#!/bin/bash

set -eu
trap 'echo "[ERROR] Script failed at line $LINENO. Command: [$BASH_COMMAND] (Exit status: $?)"' ERR

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$script_dir")"
readonly script_dir project_dir

[ "$#" -gt 6 ] || {
    echo "Usage: $0 <mode> <group_id> <instance_id> <rank> <timestamp_s> <backend> <command to run...>" >&2
    exit 1
}
readonly mode="$1"
readonly group_id="$2"
readonly instance_id="$3"
readonly rank="$4"
readonly timestamp_s="$5"
readonly backend="$6"
shift 6

cd "$project_dir/$backend"
source "./k8s-config.sh"

readonly profile_dir_prefix="$my_service_profile_base_dir/$(date +"%y%m/%d/%y%m%d-%H%M%S$timezone" -d "@$timestamp_s")"
readonly prefill_profile_dir="$profile_dir_prefix-prefill"
readonly decode_profile_dir="$profile_dir_prefix-decode"

args=(env)
if [ "$mode" = "prefill" ]; then
    args+=("MY_SERVICE_TORCH_PROFILER_DIR_PREFILL=$prefill_profile_dir")
elif [ "$mode" = "decode" ]; then
    args+=("MY_SERVICE_TORCH_PROFILER_DIR_DECODE=$decode_profile_dir")
fi
args+=("$@")

file_id=$mode
if [ "$mode" = "prefill" ] || [ "$mode" = "decode" ]; then
    file_id="${file_id}-${instance_id}"
fi
cmd=(
    env
    "MY_LOG_BASE_DIR=$my_log_base_dir"
    "MY_LOG_FILE_ID=$file_id"
    "MY_LOG_PROGRAM_NAME=$mode"
    "MY_LOG_PROGRAM_RANK=$rank"
    "MY_LOG_TIMESTAMP_S=$timestamp_s"
    "MY_LOG_USE_EXACT_TIMESTAMP_DIR=1"
    "MY_LOG_GROUP_BY_TIMESTAMP=1"
    "../utils/launch-and-log.sh"
)

(set -x; "${cmd[@]}" "${args[@]}")
