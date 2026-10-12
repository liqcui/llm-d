#!/bin/bash

set -euE
shopt -s inherit_errexit

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$script_dir")"
readonly script_dir project_dir

# shellcheck source=../utils/error.sh
source "$project_dir/utils/error.sh"

[ "$#" -eq 3 ] || {
    echo "Usage: $0 <master node ip> <nnodes> <node rank>" >&2
    exit 1
}

readonly master_node_ip="$1"
readonly nnodes="$2"
readonly node_rank="$3"

# ⚠️ 必须显式传**空**的 model spec：common.sh 会把调用者的 $1 当成模型规格，
#    而本脚本的 $1 是 master IP ⇒ 不传就会
#      Error: Model specification '{{IP_LEGACY_SAMPLE}}' could not be resolved ... (common.sh:31)
#    （2026-09-21 实测；空字符串会让它跳过模型路径解析，本用例只需要 MOONCAKE_* env）
source "$script_dir/common.sh" "" ""

sglang_python_dir="$(pip show sglang | perl -nle 'print $1 if /Editable project location: (.*)/')"
[ -z "$sglang_python_dir" ] && {
    sglang_python_dir="$(pip show sglang | perl -nle 'print $1 if /Location: (.*)/')/sglang"
}
readonly sglang_python_dir
[ -d "$sglang_python_dir" ] || log_fatal "Failed to determine sglang python package directory."

cd "$sglang_python_dir"
(set -x; python3 test_mooncake_store.py) || log_fatal "Mooncake store test failed."
