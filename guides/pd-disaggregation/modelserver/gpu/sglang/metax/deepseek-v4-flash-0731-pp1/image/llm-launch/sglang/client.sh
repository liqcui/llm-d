#!/bin/bash

set -euE
shopt -s inherit_errexit

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$script_dir")"
readonly script_dir project_dir

readonly dataset_path="/bgfs/deepseek-pd/dataset/ShareGPT_V3_unfiltered_cleaned_split.json"

# shellcheck source=../utils/error.sh
source "$project_dir/utils/error.sh"

[ "$#" -eq 2 ] || {
    echo "Usage: $0 <model spec> <server ip>" >&2
    exit 1
}
readonly arg_model_spec="$1"
readonly arg_server_addr="$2"

source "$script_dir/common.sh" "$arg_model_spec"

check_commands curl jq || log_fatal "Required commands are not available"

readonly server_ip="${arg_server_addr%:*}"
server_port="${arg_server_addr##*:}"
if [ "$server_port" = "$server_ip" ]; then
    server_port="80"
elif [[ "|prefill|decode|minilb|" = *"|$server_port|"* ]]; then
    server_port="${server_port}_server_port"
    server_port="${!server_port}"
fi
readonly server_port
readonly server_addr="$server_ip:$server_port"
[ -n "$server_port" ] || log_fatal "Failed to get server port for ip $server_ip from config."

get_server_info() {
    if [ "$sglang_version" = "v0.5.1" ]; then
        local -r l_endpoint="/get_server_info"
    else
        local -r l_endpoint="/get_server_info"
    fi

    server_info="$(curl -sS -X GET "http://$server_addr$l_endpoint")"
    [[ "$server_info" == "{"* ]] || log_fatal "Failed to get server info from http://$server_addr$l_endpoint: $server_info"
    echo "$server_info"
}

get_dp_size() {
    local -r l_server_info="$1"
    local -r l_type="$2"
    echo "$l_server_info" | jq '([.'"$l_type"'[]?.dp_size] | add) // .dp_size'
}

get_max_total_num_tokens() {
    local -r l_server_info="$1"
    local -r l_type="$2"
    echo "$l_server_info" | jq '([.'"$l_type"'[]?.max_total_num_tokens] | min) // .max_total_num_tokens'
}

get_mtp() {
    local -r l_server_info="$1"
    local -r l_type="$2"
    echo "$l_server_info" | jq '([.'"$l_type"'[]?.speculative_num_draft_tokens] | min) // .speculative_num_draft_tokens // 0'
}

check_service_health() {
    [ "$(get_dp_size "$(get_server_info)" "decode")" -gt 0 ]
}

server_info="$(get_server_info)"
prefill_dp="$(get_dp_size "$server_info" "prefill")"
decode_dp="$(get_dp_size "$server_info" "decode")"
prefill_tokens="$(get_max_total_num_tokens "$server_info" "prefill")"
decode_tokens="$(get_max_total_num_tokens "$server_info" "decode")"
decode_mtp="$(get_mtp "$server_info" "decode")"
readonly server_info prefill_dp decode_dp prefill_tokens decode_tokens decode_mtp
echo "Server info:"
echo "  DP: prefill $prefill_dp, decode $decode_dp"
echo "  Max total num tokens: prefill $prefill_tokens, decode $decode_tokens"
echo "  Decode speculative num draft tokens: $decode_mtp"
[[ "$decode_dp" -gt 0 ]] || log_fatal "Failed to get valid Decode DP($decode_dp)"

get_max_bs() {
    local -r l_in_len="$1"
    local -r l_out_len="$2"
    local tokens_per_prompt=$((l_in_len + l_out_len + 1))
    local l_max_bs="0"
    l_max_bs=$((decode_tokens / tokens_per_prompt))
    [ "$l_max_bs" -gt 0 ] || log_fatal "Requires at least $tokens_per_prompt tokens, currently $decode_tokens tokens, missing $((tokens_per_prompt - decode_tokens)) tokens."
    echo "$l_max_bs"
}

bench_serving() {
    local num_prompts="$1"
    local max_concurrency="$2"
    local input_len="$3"
    local output_len="$4"
    local request_rate="$5"
    local max_concurrency_prefill="${6:-}"

    [ "$num_prompts" -gt 0 ] || log_fatal "num_prompts should be greater than 0"

    [ "$max_concurrency" -gt 0 ] || log_fatal "max_concurrency should be greater than 0"

    args=(
        --host="$server_ip"
        --port="$server_port"
        --backend=sglang
        --dataset-name=random
        --num-prompts="$num_prompts"
        --max-concurrency="$max_concurrency"
        --random-input="$input_len"
        --random-output="$output_len"
        --random-range-ratio=1.0
        --dataset-path="$dataset_path"
        --model="$model_path"
        --pd-separated
    )
    [ -n "$request_rate" ] && {
        args+=(--request-rate="$request_rate")
    }

    [ -n "$max_concurrency_prefill" ] && {
        args+=(--max-concurrency-prefill="$max_concurrency_prefill")
    }

    date +"bench start: %Y-%m-%d %H:%M:%S.%6N"
    (set -x; python3 -m sglang.bench_serving "${args[@]}") || log_fatal "Bench failed with args: ${args[*]}"
}

bench() {
    batch_size="$1"
    input_length="$2"
    output_length="$3"
    request_rate="$4"
    num_prompts_rate="${5:-8}"
    max_concurrency="$((batch_size * decode_dp))"
    num_prompts="$((max_concurrency * num_prompts_rate))"
    bench_serving "$num_prompts" "$max_concurrency" "$input_length" "$output_length" "$request_rate"
}

cd "/tmp"
# find . -maxdepth 1 -type f -name 'sglang_*_23552_1024.jsonl' -exec stat -c "%Y,%n" {} + | awk -F, '$1>max {max=$1; file=$2} END {print file}'
# cat *.json | jq '.mean_tpot_ms'
# cat *.json | jq '.mean_ttft_ms'

env MY_CURL_CLIENT_MODEL_PATH="$model_path" \
"$project_dir/utils/curl-client.sh" "$server_addr" "generate" "$project_dir/assets/prompts.json"

[ "$LLM_LAUNCH_ENV" = "release" ] && {
    bench 32 2048 2048 17 3
    bench 32 2048 2048 17
    exit 0
}

true
