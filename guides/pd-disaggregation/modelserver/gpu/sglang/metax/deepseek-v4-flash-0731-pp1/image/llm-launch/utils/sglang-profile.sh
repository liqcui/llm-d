#!/bin/bash

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(cd "$script_dir/.." && pwd)"
readonly script_dir project_dir
cd "$project_dir"

[ "$#" -eq 1 ] || [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || {
    echo "Usage: $0 <server addr> [sleep time] [echo]" >&2
    exit 1
}

readonly server_addr="$1"
readonly sleep_time="${2:-5}"
readonly echo_only="${3:-}"

if [ -z "$echo_only" ]; then
    cmd_curl=(curl)
else
    cmd_curl=(echo curl)
fi

cmd_curl+=(
    -Ss
    -X POST
    --connect-timeout 5
)

(set -x; "${cmd_curl[@]}" --max-time 20 "http://$server_addr/start_profile")
sleep "$sleep_time"
(set -x; "${cmd_curl[@]}" "http://$server_addr/stop_profile")

