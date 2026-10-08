#!/bin/bash

_utils_k8s_devices_sh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

get-group-ip() {
    sed -n '/group_'"$1"'_configs/,/^)$/p' "$_utils_k8s_devices_sh_script_dir/k8s-label.sh" | grep -vP '^\s*#' |  grep -oP '\d+(\.\d+){3}' | sort -uV
}

readarray -t k8s_nodes_ip_1 < <(get-group-ip 1)
readarray -t k8s_nodes_ip_2 < <(get-group-ip 2)
readarray -t k8s_nodes_ip_3 < <(get-group-ip 3)

k8s-nodes-ip-all() {
    printf "%s\n" "${k8s_nodes_ip_1[@]}" "${k8s_nodes_ip_2[@]}" "${k8s_nodes_ip_3[@]}" | sort -uV
}

grep-ip-op() {
    grep -oP '\d+(\.\d+){3}'
}

grep-nodes() {
    grep -P ' ('"$(sed -e 's/\./\\./g' -e 's/ /|/g' <<< "$*")"')(\D|$)|NAME' | cat
}

grep-nodes-pd-1() {
    grep-nodes "${k8s_nodes_ip_1[*]}"
}

grep-nodes-pd-2() {
    grep-nodes "${k8s_nodes_ip_2[*]}"
}

grep-nodes-pd-3() {
    grep-nodes "${k8s_nodes_ip_3[*]}"
}

grep-nodes-pd() {
    grep-nodes "$(k8s-nodes-ip-all)"
}

k8s-kubectl-get-nodes() {
    cmd_kubectl() {
        kubectl get nodes -o wide -L pd-role -L pd-minilb -L pd-client
    }
    eval "$(cmd_kubectl | head -1 | grep -boP '\S+' | awk -F: '
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
    kubectl_simplify() {
        # shellcheck disable=SC2154
        cut "-b$k8s_title_name,$k8s_title_status,$k8s_title_internal_ip,$k8s_title_pd_role,$k8s_title_pd_minilb,$k8s_title_pd_client"
    }
    cmd_kubectl | head -1 | kubectl_simplify | cat -n | sed 's/1/_/'
    cmd_kubectl | grep '^i-' | kubectl_simplify | cat -n | sed 's/$/ /'
}
