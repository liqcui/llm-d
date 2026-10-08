#!/bin/bash

set -euE
trap 'echo "[ERROR] Script failed at line $LINENO. Command: [$BASH_COMMAND] (Exit status: $?)" >&2' ERR

script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly script_dir

readonly keep_even_rows="${1:-}"
[ "$keep_even_rows" = "keep-even" ] && shift
readonly files=("$@")

get_server_instances() {
    find -L "$1" -maxdepth 1 -type f -printf "%f\0"        \
        | perl -0nle 'print $1 if /^log-(.*)-\d{2}-\d{6}/' \
        | sort -zu                                         \
        | grep -zc .
}

get_latest_file() {
    find -L "$1" -maxdepth 1 -type f -exec stat -c "%W,%n" {} + | sort -nr | head -1 | cut -d, -f2-
}

get_peer_log_dir() {
    local -r l_client_dir="$1"
    local -r l_role="$2"
    local -r l_client_base="$(basename "$l_client_dir")"
    local -r l_client_parent="$(dirname "$l_client_dir")"

    if [ "$l_client_base" = "client" ]; then
        echo "$l_client_parent/$l_role"
    elif [[ "$l_client_base" = *"-client" ]]; then
        echo "$l_client_parent/${l_client_base%client}$l_role"
    else
        return 1
    fi
}

get_server_arg() {
    local -r l_dir="$1"
    local -r l_arg="$2"
    perl -nle 'if (/'"$l_arg"'=(\w+)/) { print $1; exit }' "$(get_latest_file "$l_dir")"
}

get_server_dp_size() {
    get_server_arg "$1" "dp_size"
}
get_server_ep_size() {
    get_server_arg "$1" "tp_size"
}

get_server_tp_size() {
    get_server_arg "$1" "tp_size"
}

get_server_tbo() {
    get_server_arg "$1" "enable_two_batch_overlap"
}

get_server_disable_graph() {
    get_server_arg "$1" "disable_cuda_graph"
}

get_server_mtp() {
    get_server_arg "$1" "speculative_num_draft_tokens"
}

get_chunked_prefill_size() {
    get_server_arg "$1" "chunked_prefill_size"
}

for i in "${files[@]}"; do
    [ -f "$i" ] || {
        echo "$i is not a valid file" >&2
        continue
    }
    file="$i"
    client_dir="$(realpath "$(dirname "$file")")"
    prefill_dir="$(get_peer_log_dir "$client_dir" prefill)" || {
        echo "Cannot infer prefill directory from client directory $client_dir for client file $file" >&2
        continue
    }
    decode_dir="$(get_peer_log_dir "$client_dir" decode)" || {
        echo "Cannot infer decode directory from client directory $client_dir for client file $file" >&2
        continue
    }
    { [ -d "$prefill_dir" ] && [ -d "$decode_dir" ] ; } || {
        echo "Either prefill directory $prefill_dir or decode directory $decode_dir does not exist for client file $file" >&2
        continue
    }

    prefill_chunk_size="$(($(get_chunked_prefill_size "$prefill_dir") / $(get_server_dp_size "$prefill_dir")))"
    args=(
        --prefills "$(get_server_instances "$prefill_dir")"
        --prefill-cards 16
        --decodes "$(get_server_instances "$decode_dir")"
        --decode-cards "$(get_server_ep_size "$decode_dir")"
        --prefill-chunk-size "$prefill_chunk_size"
        --tbo "$(get_server_tbo "$decode_dir")"
        --disable-graph "$(get_server_disable_graph "$decode_dir")"
        --mtp "$(get_server_mtp "$decode_dir")"
    )
    [ "$keep_even_rows" = "keep-even" ] && args+=(--keep-even-rows)
    "$script_dir/bench-serving-to-csv.sh" "$file" | tail -n +2 | python3 "$script_dir/bench-serving-format.py" "${args[@]}"
done
