#!/bin/bash

set -eu
trap 'echo "[ERROR] Script failed at line $LINENO. Command: [$BASH_COMMAND] (Exit status: $?)"' ERR

script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly script_dir

usage() {
    echo "Usage: $0 sglang|vllm <group id> [clean]" >&2
    exit 1
}

[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || {
    usage
}

readonly backend="$1"
readonly group_id="$2"
readonly action="$3"
[[ "||sglang|vllm|" = *"|$backend|"* ]] || usage
[[ "||clean|" = *"|$action|"* ]] || usage

[ -f "$script_dir/$backend/k8s-config.sh" ] || {
    echo "Error: Config file for backend '$backend' not found." >&2
    exit 1
}
# shellcheck disable=SC1090
source "$script_dir/$backend/k8s-config.sh"

# kubectl get namespace "$k8s_namespace" &>/dev/null || kubectl create namespace "$k8s_namespace"

kubectl_get_nodes() {
    kubectl get nodes -o wide -L pd-role -L pd-minilb -L pd-client
}

readarray -t group_all_nodes_info < <(kubectl_get_nodes | grep ' Ready ' | grep " group-$group_id")

[ "${#group_all_nodes_info[@]}" -gt 0 ] || {
    echo "Error: No nodes found for group-$group_id. Please check your node labels." >&2
    exit 1
}
echo "Found ${#group_all_nodes_info[@]} nodes for group-$group_id."

eval "$(kubectl_get_nodes | head -1 | grep -boP '\S+' | awk -F: '
    {
        $2 = tolower($2);
        gsub("-", "_", $2);
        if (l2 != "") {
            printf "k8s_title_%s=%d-%d\n", l2, l1, $1
        }
        l1=$1+1;
        l2=$2
    }
    END {
        printf "k8s_title_%s=%d-\n", l2, l1
    }
')"

nodes_prefill_decode="$(printf "%s\n" "${group_all_nodes_info[@]}" | cut "-b$k8s_title_pd_role" | xargs -n1 | grep -vP '^\s*$')"
nnodes=()
for i in $(seq "$prefill_instance"); do
    r0="$(echo "$nodes_prefill_decode" | grep -c "prefill-$i-r0$")"
    n="$(echo "$nodes_prefill_decode" | grep -c "prefill-$i$")"
    [ "$r0" -eq 1 ] || {
        echo "Error: No node with role 'group-$group_id-prefill-$i-r0' found." >&2
        exit 1
    }
    [ "$n" -ge "$((prefill_nnodes - 1))" ] || {
        echo "Error: Not enough nodes with role 'group-$group_id-prefill-$i'. Found $n, required $((prefill_nnodes - 1))." >&2
        exit 1
    }
    nnodes+=("$((n + 1))")
done
echo "Nodes allocated for prefill: ${nnodes[*]}"
nnodes=()
for i in $(seq "$decode_instance"); do
    r0="$(echo "$nodes_prefill_decode" | grep -c "decode-$i-r0$")"
    n="$(echo "$nodes_prefill_decode" | grep -c "decode-$i$")"
    [ "$r0" -eq 1 ] || {
        echo "Error: No node with role 'group-$group_id-decode-$i-r0' found." >&2
        exit 1
    }
    [ "$n" -ge "$((decode_nnodes - 1))" ] || {
        echo "Error: Not enough nodes with role 'group-$group_id-decode-$i'. Found $n, required $((decode_nnodes - 1))." >&2
        exit 1
    }
    nnodes+=("$((n + 1))")
done
echo "Nodes allocated for decode: ${nnodes[*]}"

nodes_minilb="$(printf "%s\n" "${group_all_nodes_info[@]}" | cut "-b$k8s_title_pd_minilb" | grep -vP '^\s*$')"
n="$(echo "$nodes_minilb" | grep -cF "group-$group_id")"
[ "$n" -eq 1 ] || {
    echo "Error: There should be exactly 1 node with minilb label 'group-$group_id'. Found $n." >&2
    exit 1
}
echo "Nodes with minilb label 'group-$group_id': $n"

nodes_client="$(printf "%s\n" "${group_all_nodes_info[@]}" | cut "-b$k8s_title_pd_client" | grep -vP '^\s*$')"
n="$(echo "$nodes_client" | grep -cF "group-$group_id")"
[ "$n" -ge 1 ] || {
    echo "Error: No nodes with client label 'group-$group_id' found. Found $n, required at least 1." >&2
    exit 1
}
echo "Nodes with client label 'group-$group_id': $n"

readonly timestamp_s="$(date +'%s')"
k8s_manifest() {
    local -r f_args=(
        --group-id="$group_id"
        --backend="$backend"
        --image="$image"
        --timestamp-s="$timestamp_s"
        --container-project-root-dir="$container_project_root_dir"
        "$@"
    )
    python3 "$script_dir/k8s/manifest-generator.py" "${f_args[@]}"
}

for i in $(seq "$prefill_instance"); do
    master_ip="$(printf "%s\n" "${group_all_nodes_info[@]}" | grep -F "group-$group_id-prefill-$i-r0" | cut -b"$k8s_title_internal_ip" | xargs -n1)"
    for rank in $(seq 0 $((prefill_nnodes - 1))); do
        label="pd-role=group-$group_id-prefill-$i"
        [ "$rank" -eq 0 ] && label="${label}-r0"
        k8s_manifest --node-labels="$label" --mode=prefill --instance-id="$i" --master-ip="$master_ip" --nnodes="$prefill_nnodes" --rank="$rank" --mounts "/dev/infiniband:/dev/infiniband" "/bgfs:/bgfs"
    done
done

for i in $(seq "$decode_instance"); do
    master_ip="$(printf "%s\n" "${group_all_nodes_info[@]}" | grep -F "group-$group_id-decode-$i-r0" | cut -b"$k8s_title_internal_ip" | xargs -n1)"
    for rank in $(seq 0 $((decode_nnodes - 1))); do
        label="pd-role=group-$group_id-decode-$i"
        [ "$rank" -eq 0 ] && label="${label}-r0"
        k8s_manifest --node-labels="$label" --mode=decode --instance-id="$i" --master-ip="$master_ip" --nnodes="$decode_nnodes" --rank="$rank" --mounts "/bgfs:/bgfs" "/dev/infiniband:/dev/infiniband"
    done
done

awk_minilb_row() {
    local minilb_column_start="$(echo "$k8s_title_pd_minilb" | cut -d- -f1)"
    awk -v s="$minilb_column_start" -v l="$(($(echo "$k8s_title_pd_minilb" | cut -d- -f2) - minilb_column_start + 1))" -v t="group-$group_id" '{
            val = substr($0, s, l)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
            if (val == t) {
                print $0
            }
        }'
}

minilb_ip="$(printf "%s\n" "${group_all_nodes_info[@]}" | awk_minilb_row | cut -b"$k8s_title_internal_ip" | xargs -n1)"
[ -n "$minilb_ip" ] || [ "$(echo -n "$minilb_ip" | grep -c .)" -eq 1 ] || {
    echo "Error: Failed to determine minilb IP. Found: '$minilb_ip'" >&2
    exit 1
}

k8s_manifest --node-labels="pd-minilb=group-$group_id" --mode=minilb --prefill="" --decode="" --mounts "/bgfs:/bgfs"
k8s_manifest --node-labels="pd-client=group-$group_id" --mode=client --server-addr="${minilb_ip}:minilb" --mounts "/bgfs:/bgfs"
