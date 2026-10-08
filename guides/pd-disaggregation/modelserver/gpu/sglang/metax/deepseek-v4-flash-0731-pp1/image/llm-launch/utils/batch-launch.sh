#!/bin/bash

set -euE
shopt -s inherit_errexit
trap 'echo "[ERROR] Script failed at line $LINENO. Command: [$BASH_COMMAND] (Exit status: $?)" >&2' ERR

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$script_dir")"
readonly script_dir project_dir

cd "$project_dir"

for model in glm-5 deepseek-v3.2 deepseek-v3 minimax-m2; do
    ./launch-in-tmux.sh sglang "$model" wait
    sleep 10
done
