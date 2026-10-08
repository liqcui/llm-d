#!/bin/bash

set -euE
shopt -s inherit_errexit
export TIMEFORMAT="%Rs total %Us user %Ss system %P%% cpu"

script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly script_dir

[ "$#" -ge 1 ] && [ "$#" -le 3 ] || {
    echo "Usage: $0 group_id|addr [generate|completions] [prompts json file]" >&2
    exit 1
}

readonly arg_addr="$1"
readonly arg_method="${2:-generate}"
readonly arg_prompts_file="${3:-}"

check_commands() {
    local missing_cmds=()
    local cmd

    for cmd in "$@"; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            missing_cmds+=("$cmd")
        fi
    done

    if [ ${#missing_cmds[@]} -ne 0 ]; then
        echo "The following required commands are missing:"
        for m in "${missing_cmds[@]}"; do
            echo "  - $m"
        done
        return 1
    fi

    return 0
}

check_commands jq curl

[ -z "$arg_prompts_file" ] && {
    readonly prompt_text="SWITZERLAND（瑞士）的字母可以重新排列成LIZARD（蜥蜴）和NEWTS（蝾螈）两个单词，LIZARD是一个动物的单数形式，而NEWTS是复数形式。请再说出另一个具有相同特性的国家。即另一个其字母可以重新排列来拼写两种动物——一个单数和一个复数的国家。它是一个主要国家。这个国家是哪一个？"
}

args=(
    -X POST
    -H "Content-Type: application/json"
)

body_prompt_key=""
body_template=""
if [ "$arg_method" = "generate" ]; then
    args+=("http://$arg_addr/generate")
    body_prompt_key=".text"
    # 这里的 model 是多余的，仅为从请求中看到模型
    body_template='{
        "model": "'"${MY_CURL_CLIENT_MODEL_PATH:-default}"'",
        "text": "prompt",
        "ignore_eos": false,
        "sampling_params": {
            "max_new_tokens": 256,
            "top_k": 1
        }
    }'
elif [ "$arg_method" = "completions" ]; then
    args+=("http://$arg_addr/v1/completions")
    body_prompt_key=".prompt"
    body_template='{
        "model": "'"${MY_CURL_CLIENT_MODEL_PATH:-default}"'",
        "prompt": "prompt",
        "temperature": 0.0,
        "repetition_penalty": 1.0,
        "max_tokens": 256,
        "logprobs": null,
        "stream": false,
        "ignore_eos": false
    }'
else
    echo "Invalid method: '$arg_method'" >&2
    exit 1
fi

grep_value_by_key_int() {
    grep -oP '(?<="'"$1"'")\s*:\s*\d+' | tr -d ': '
}

prompts_number=1
[ -n "$arg_prompts_file" ] && {
    prompts_number="$(jq '.prompts | length' "$arg_prompts_file")"
    [ "$prompts_number" -gt 0 ] || {
        echo "No prompts found in '$arg_prompts_file'." >&2
        exit 1
    }
}

for i in $(seq 0 $((prompts_number - 1))); do
    echo
    if [ -n "$arg_prompts_file" ]; then
        prompt="$(jq -r ".prompts[$i]" "$arg_prompts_file")"
    elif [ -n "$prompt_text" ]; then
        prompt="$prompt_text"
    else
        echo "No prompt provided." >&2
        exit 1
    fi
    body="$(echo "$body_template" | jq --arg prompt "$prompt" "$body_prompt_key"' = $prompt')"
    echo curl -sS "${args[@]}" -d "$body" | cut -c1-512
    resp=$(time curl -sS "${args[@]}" -d "$body")

    # echo "$resp" | jq
    prompt_tokens="$(echo "$resp" | grep_value_by_key_int "prompt_tokens")"
    completion_tokens="$(echo "$resp" | grep_value_by_key_int "completion_tokens")"
    total_tokens=$(echo "$resp" | grep_value_by_key_int "total_tokens")
    [ -z "$prompt_tokens" ] && echo "$resp" && exit 1
    [ -z "$total_tokens" ] && total_tokens=$((prompt_tokens + completion_tokens))
    echo "tokens: $total_tokens = $prompt_tokens + $completion_tokens"
    text=$(echo "$resp" | jq '.text // .choices[0].text // .choices[0].message.content // ""')
    echo "output: $text"
done
