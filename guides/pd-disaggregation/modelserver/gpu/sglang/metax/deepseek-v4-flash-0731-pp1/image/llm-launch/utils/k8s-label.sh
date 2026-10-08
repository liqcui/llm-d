#!/bin/bash

set -eu

script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly script_dir
project_dir="$(cd "$script_dir/.." && pwd)"
readonly project_dir
cd "$project_dir"

[ "$#" -eq 1 ] || {
    echo "Usage: $0 <group-id>"
    exit 1
}

readonly config_name="group_${1}_configs"

group_1_configs=(
    "node_ip=10.200.119.121;label_key=pd-client;label_value=group-1"
    "node_ip=10.200.119.122;label_key=pd-minilb;label_value=group-1"

    "node_ip=10.200.119.86 ;label_key=pd-role;label_value=" # w
    "node_ip=10.200.119.89 ;label_key=pd-role;label_value=" # w
    "node_ip=10.200.119.26 ;label_key=pd-role;label_value=" # w
    "node_ip=10.200.119.123;label_key=pd-role;label_value=" # w
    "node_ip=10.200.119.28 ;label_key=pd-role;label_value=" # w
    "node_ip=10.200.119.60 ;label_key=pd-role;label_value=" # w
    "node_ip=10.200.119.83 ;label_key=pd-role;label_value=" # w
    "node_ip=10.200.119.65 ;label_key=pd-role;label_value=" # w
    "node_ip=10.200.119.4  ;label_key=pd-role;label_value=group-1-prefill-1-r0" # h
    "node_ip=10.200.119.57 ;label_key=pd-role;label_value=group-1-prefill-1" # h
    "node_ip=10.200.119.118;label_key=pd-role;label_value=group-1-decode-1-r0" # h
    "node_ip=10.200.119.120;label_key=pd-role;label_value=" # z
    "node_ip=10.200.119.122;label_key=pd-role;label_value=" # z
    "node_ip=10.200.119.117;label_key=pd-role;label_value=group-1-decode-1" # h
    "node_ip=10.200.119.121;label_key=pd-role;label_value=group-1-decode-1"
    "node_ip=10.200.119.119;label_key=pd-role;label_value=group-1-decode-1" # h
)

# declare -n # bash 4.3
eval "readonly configs=(\"\${$config_name[@]}\")"
[ "${#configs[@]}" -gt 1 ] || {
    echo "Not enough configs"
    exit 1
}

[ "$1" = "clean" ] && {
    for cfg in "${configs[@]}"; do
        eval "$cfg"
        kubectl label nodes $(kubectl get nodes | grep -oP '^\S+') "${label_key}-" || true
    done
    exit 0
}

for cfg in "${configs[@]}"; do
    eval "$cfg"
    node="$(kubectl get nodes -o wide | grep -F " $node_ip " | grep -oP '^\S+' || true)"
    [ -z "$node" ] && {
        echo "Cannot find node with IP=$node_ip"
        exit 1
    }
    label_cur="$(kubectl get nodes "$node" -L "$label_key" | awk -v col_name="${label_key^^}" 'NR==1{for(i=1;i<=NF;i++){if($i==col_name){col=i;break}}} NR>1{print $col}')"
    printf "node=$node, node_ip=%-15s, %11s=%-15s -> %-9s\n" "$node_ip" "$label_key" "$label_cur" "$label_value"
    [ "$label_cur" = "$label_value" ] && continue
    [ -n "$label_cur" ] && {
        kubectl label nodes "$node" "$label_key"-
    }
    [ -n "$label_value" ] && {
        kubectl label nodes "$node" "$label_key"="$label_value"
    }
done
