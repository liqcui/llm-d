#!/bin/bash

set -euE
shopt -s inherit_errexit

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$script_dir")"
readonly script_dir project_dir

# shellcheck source=../utils/error.sh
source "$project_dir/utils/error.sh"

# shellcheck source=./common.sh
source "$script_dir/common.sh"

readonly args=(
    -rpc_address="$local_ip"
    -rpc_port="$mooncake_master_port"
    -eviction_high_watermark_ratio=0.95
    -enable_metric_reporting=false

    -enable_http_metadata_server=true
    -http_metadata_server_host="$local_ip"
    -http_metadata_server_port="$mooncake_metadata_port"
)

show_filtered_env
(set -x; mooncake_master "${args[@]}") || log_fatal "Mooncake master exited with code $?"

