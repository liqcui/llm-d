#!/bin/bash

set -euE
shopt -s inherit_errexit

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$script_dir")"
readonly script_dir project_dir
#readonly model_spec="deepseek-v4-pro"

# shellcheck source=../utils/error.sh
source "$project_dir/utils/error.sh"

[ "$#" -ge 4 ] || {
    echo "Usage: $0 prefill <prefill id>... decode <decode ip>... " >&2
    exit 1
}

prefill=()
decode=()
while [ "$#" -gt 0 ]; do
    if [ "$1" = "prefill" ] || [ "$1" = "decode" ]; then
        declare -n ref="$1"
    else
        ref+=("$1")
    fi
    shift
done

source "$script_dir/common.sh"

args=(
    --host="$local_ip"
    --port="$minilb_server_port"
)

if [ "$sglang_version" = "v0.5.1" ]; then
    readonly program="sglang.srt.disaggregation.mini_lb"
    args+=(--prefill)
    for prefill_ip in "${prefill[@]}"; do
        args+=("http://$prefill_ip:$prefill_server_port")
    done
    args+=(--decode)
    for decode_ip in "${decode[@]}"; do
        args+=("http://$decode_ip:$decode_server_port")
    done
elif [ "$sglang_version" = "v0.5.7" ]; then
    readonly program="sglang_router.launch_router"
    for prefill_ip in "${prefill[@]}"; do
        args+=(--prefill "http://$prefill_ip:$prefill_server_port")
    done
    for decode_ip in "${decode[@]}"; do
        args+=(--decode "http://$decode_ip:$decode_server_port")
    done
    args+=(--pd-disaggregation --mini-lb)
else
    readonly program="sglang_router.launch_router"
    for prefill_ip in "${prefill[@]}"; do
        args+=(--prefill "http://$prefill_ip:$prefill_server_port")
    done
    for decode_ip in "${decode[@]}"; do
        args+=(--decode "http://$decode_ip:$decode_server_port")
    done
    args+=(--pd-disaggregation --request-timeout-secs 18000 --health-check-timeout-secs=90)
fi

load_balance_method_shortest_queue && {
    args+=(--enable-shortest-queue)
}

# export SGLANG_DEBUG_SHORTEST_QUEUE=1

show_filtered_env
(set -x; python3 -m "$program" "${args[@]}") || log_fatal "Mini LB server exited with code $?"
