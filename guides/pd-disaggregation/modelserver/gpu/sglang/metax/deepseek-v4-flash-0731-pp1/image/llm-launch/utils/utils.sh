# shellcheck shell=bash

_utils_utils_sh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_utils_utils_sh_project_dir="$(dirname "$_utils_utils_sh_script_dir")"

version_lt() {
    [ "$#" -eq 2 ] || {
        echo "Usage: version_lt <version1> <version2>" >&2
        return 1
    }
    local -r l_va="$1"
    local -r l_vb="$2"
    ! echo -e "$l_vb\n$l_va" | sort -V -C
}

version_eq() {
    [ "$#" -eq 2 ] || {
        echo "Usage: version_eq <version1> <version2>" >&2
        return 1
    }
    [ "$1" = "$2" ]
}

version_le() {
    [ "$#" -eq 2 ] || {
        echo "Usage: version_le <version1> <version2>" >&2
        return 1
    }
    local -r l_va="$1"
    local -r l_vb="$2"
    version_lt "$l_va" "$l_vb" || version_eq "$l_va" "$l_vb"
}

is_not_empty() {
    [ -n "$1" ] && echo 1 || echo 0
}

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

    true
}

sort_args() {
    local sep_value=$'\x1'
    local sep_sort=$'\x2'
    local args_=()
    for i in "$@"; do
        args_+=("${i//$'\n'/$sep_value}")
    done
    local args_sorted
    readarray -t args_sorted < <(printf "%s\n" "${args_[@]}" | awk -v sep="$sep_sort" '{
        if ($0 ~ /^-/) {
            printf (NR == 1? "": "\n") $0
        } else {
            printf sep $0
        }
    }' | sort | sed "s/$sep_sort/\n/g")
    for i in "${args_sorted[@]}"; do
        printf "%s\0" "${i//$sep_value/$'\n'}"
    done
}

path_prepend() {
    declare -n var_ref="$1"
    var_ref="$(echo -e "$(printf "%s\n" "${@:2}")\n$(echo "$var_ref" | awk -v RS=: "1")" | awk 'NF && !a[$1]++' | paste -sd:)"
}

if command -v jq >/dev/null; then
    json_compact() {
        local cmd_=(jq -c .)
        if [ -n "$1" ]; then
            echo "$1" | "${cmd_[@]}"
        else
            "${cmd_[@]}"
        fi
    }
elif command -v python3 >/dev/null; then
    json_compact() {
        local cmd_=(python3 -c "import json, sys; print(json.dumps(json.load(sys.stdin), separators=(',', ':')))")
        if [ -n "$1" ]; then
            echo "$1" | "${cmd_[@]}"
        else
            "${cmd_[@]}"
        fi
    }
else
    json_compact() {
        echo "Error: json_compact requires 'jq' or 'python3'" >&2
        return 1
    }
fi

if command -v ht-smi >/dev/null && ht-smi | grep -q ======; then
    readonly cmd_smi="ht-smi"
    readonly sdk_arch="mars"
elif command -v mx-smi >/dev/null && mx-smi | grep -q ======; then
    readonly cmd_smi="mx-smi"
    readonly sdk_arch="maca"
elif command -v nvidia-smi >/dev/null && nvidia-smi | grep -q ======; then
    readonly cmd_smi="nvidia-smi"
    readonly sdk_arch="cuda"
fi

get_gpu_name() {
    "$cmd_smi" | perl -nle 'if (/^\s*\|\s*\d+\s+([^|]+)/) { my $s = lc($1); $s =~ s/[^a-z0-9]+/-/g; $s =~ s/^-+|-+$//g; $s =~ s/-(on|off)//g;  print $s; exit }'
}

get_num_gpus() {
    "$cmd_smi" | sed -n '/^+-/,/^ *$/ { p; /^ *$/q; }' | grep -cF 'MiB '
}

get_num_dies() {
    local gpu_name=""
    gpu_name="$(get_gpu_name)"
    local num_gpus=""
    num_gpus="$(get_num_gpus)"
    if [[ "|metax-c588|metax-c600|" = *"|$gpu_name|"* ]]; then
        echo -n "$((num_gpus * 2))"
    else
        echo -n "$num_gpus"
    fi
}

arch_str_map() {
    local -r l_src="$1"
    local -r l_arch="$2"
    local -a l_reps
    case "$l_arch" in
        cuda) l_reps=(CUDA cuda NCCL NV nv CU) ;;
        mars) l_reps=(HPCC hpcc HCCL HT ht HC) ;;
        maca) l_reps=(MACA maca MCCL MX mx MC) ;;
        *) echo "Error: Unsupported architecture '$l_arch' in arch_str_map" >&2; return 1 ;;
    esac
    local l_sed_pat=(
        's#(^|_|\$\{?)(CUDA|HPCC|MACA)(_|$)#\1'"${l_reps[0]}"'\3#g;'
        's#(^|_|/)(cuda|hpcc|maca)(_|$)#\1'"${l_reps[1]}"'\3#g;'
        's#(^|_|\$\{?)(NCCL|HCCL|MCCL)(_|$)#\1'"${l_reps[2]}"'\3#g;'
        's#(^|_|\$\{?)(NV|HT|MX)(_|SHMEM_|TLASS|$)#\1'"${l_reps[3]}"'\3#g;'
        's#(^|_|/)(nv|ht|mx)(driver|gdrcopy|gpu_llvm|shmem|$)#\1'"${l_reps[4]}"'\3#g;'
        's#(^|_|\$\{?)(CU|HC|MC)(_|TLASS|$)#\1'"${l_reps[5]}"'\3#g;'
    )
    printf "%s" "$l_src" | sed -E "${l_sed_pat[*]}"
}

arch_str_map_cur_arch() {
    local -r l_src="$1"
    arch_str_map "$l_src" "$sdk_arch"
}

export_multi_arch() {
    local -r l_name="$1"
    local -r l_val="$2"
    local -r l_ops="${3:-}"
    echo "$l_ops" | grep -q '^[ev]*$' || {
        echo "Error: Invalid third argument to export_multi_arch: expected 'e', 'v', 've', or empty, got '$l_ops'" >&2
        return 1
    }
    local -a l_archs=("cuda")
    [ "$sdk_arch" != "cuda" ] && l_archs+=("$sdk_arch")
    local l_arch l_tmp_name l_tmp_val l_tmp_ops l_op
    for l_arch in "${l_archs[@]}"; do
        l_tmp_name="$(arch_str_map "$l_name" "$l_arch")"
        [[ "$l_tmp_name" =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || {
            echo "Error: Generated environment variable name '$l_tmp_name' is invalid." >&2
            return 1
        }
        l_tmp_val="$l_val"
        l_tmp_ops="$l_ops"
        while [ -n "$l_tmp_ops" ]; do
            case "${l_tmp_ops:0:1}" in
                e) l_tmp_val="$(eval echo "$l_tmp_val")" ;;
                v) l_tmp_val="$(arch_str_map "$l_val" "$l_arch")" ;;
            esac
            l_tmp_ops="${l_tmp_ops:1}"
        done
        export "$l_tmp_name"="$l_tmp_val"
    done
}

init_conda_python() {
    type python3 2>/dev/null | head -1 | grep -q 'conda' && return 0
    local -r l_conda_file="/opt/conda/etc/profile.d/conda.sh"
    [ -f "$l_conda_file" ] || return 0
    # shellcheck disable=SC1091
    source "$l_conda_file"
    conda activate
}

set_env_filter() {
    # 要保留的
    MY_UNIMPORTANT_ENV=$(env | grep -o '^\w\+=' | grep -vP '^(.CCL|CUDA|DEVICE|FORCE|GLOO|HPCC|HC|HT|MACA|MC|MHA|MX|NV|OMP|PYTORCH|RAY|SGLANG|TOKEN|TRITON|PATH|LD_LIBRARY_PATH|NODE_IP)' | xargs | sed -e 's/= /|/g' -e 's/=$//')
    # 要排除的
    MY_UNIMPORTANT_ENV="${MY_UNIMPORTANT_ENV:+$MY_UNIMPORTANT_ENV|}_.*"
    readonly MY_UNIMPORTANT_ENV
    export MY_UNIMPORTANT_ENV
}

show_filtered_env() {
    [ -n "$MY_UNIMPORTANT_ENV" ] || {
        echo "MY_UNIMPORTANT_ENV is not set. Call set_env_filter first." >&2
        return 0
    }
    echo "Environment variables (excluding those matching: $MY_UNIMPORTANT_ENV):"
    env | grep -vP "^($MY_UNIMPORTANT_ENV|MY_\w+)=" | sort
}

if command -v ip >/dev/null; then
    get_local_ip() {
        ip route get 8.8.8.8 | grep -oP '(?<=src )\d+(\.\d+){3}'
    }
elif command -v hostname >/dev/null; then
    get_local_ip() {
        local -r ip_prefix=""
        [ -n "$ip_prefix" ] || {
            echo "Error: ip_prefix is not set." >&2
            return 1
        }
        local l_local_ip
        l_local_ip="$(hostname -I | xargs -n1 | grep -oP "^$ip_prefix\S+")"
        [ "$(echo "$l_local_ip" | grep -c .)" -eq 1 ] || {
            echo "Error: Unable to determine unique local IP with prefix '$ip_prefix'." >&2
            return 1
        }
        echo "$l_local_ip"
    }
else
    get_local_ip() {
        echo "Error: Neither 'ip' nor 'hostname' command is available to get local IP." >&2
        return 1
    }
fi

if command -v ip >/dev/null; then
    get_net_primary_iface() {
        ip route get 8.8.8.8 | grep -oP '(?<=dev )\S+'
    }
elif command -v netstat >/dev/null; then
    get_net_primary_iface() {
        netstat -rn | grep -m1 '^0.0.0.0' | grep -oP '\S+\s*$'
    }
else
    get_net_primary_iface() {
        echo "Error: Neither 'ip' nor 'netstat' command is available to get interface name." >&2
        return 1
    }
fi

get_hca_traffic_class() {
    local -r l_hca_list="${1:-}"
    [ -n "$l_hca_list" ] || {
        echo "Warn: l_hca_list is empty." >&2
        return 1
    }

    local -a l_hca_array=()
    IFS=',' read -r -a l_hca_array < <(echo "$l_hca_list" | sed -e 's/\s*,\s*/,/g' -e 's/^\s*\|\s*$//g')
    local l_tclass_num
    l_tclass_num="$(printf "/sys/class/infiniband/%s/tc/1/traffic_class\0" "${l_hca_array[@]}" | xargs -0 cat | grep -oP '\d+')"

    [ "$(echo -n "$l_tclass_num" | grep -c .)" -eq "${#l_hca_array[@]}" ] || {
        echo "Warn: Number of traffic class entries does not match number of HCAs in '$l_hca_list'." >&2
        return 1
    }

    local l_tclass
    l_tclass="$(echo "$l_tclass_num" | sort -u)"
    [ "$(echo -n "$l_tclass" | grep -c .)" -eq 1 ] || {
        echo "Warn: Inconsistent traffic class values across HCAs in '$l_hca_list': ${l_tclass//$'\n'/ }" >&2
        return 1
    }

    echo "$l_tclass"
}

get_shmem_dir() {
    local -r l_cond_dirs=(
        "$(arch_str_map_cur_arch "/opt/cuda")"
        "$(arch_str_map_cur_arch "/opt/cuda/nvshmem")"
        "/opt/deepep"
    )
    local l_dir
    for l_dir in "${l_cond_dirs[@]}"; do
        [ -d "$l_dir" ] && [ -n "$(find "$l_dir/lib" -type f -name "lib*shmem*.so*" 2>/dev/null)" ] && {
            echo "$l_dir"
            return 0
        }
    done
    echo "Error: Failed to find valid SHMEM_PATH from candidates: ${l_cond_dirs[*]}" >&2
    return 1
}

get_git_commit_id() {
    local -r l_dir="$1"
    [ -d "$l_dir/.git" ] || {
        echo "Warn: Directory '$l_dir' is not a git repository." >&2
        return 1
    }
    local -r l_git_dir="$l_dir/.git"
    local l_head_ref=""
    l_head_ref="$(cat "$l_git_dir/HEAD")"
    [[ "$l_head_ref" = "ref: "* ]] && {
        l_head_ref="$(cat "$l_git_dir/${l_head_ref#ref: }")"
    }
    echo "${l_head_ref}" | grep -qE '^[0-9a-f]{40}$' || {
        echo "Warn: Unable to determine git commit ID for repository at '$l_dir'." >&2
        return 1
    }
    echo "${l_head_ref}"
}

get_model_type() {
    local -r l_model_path="$1"
    local l_model_type=""
    l_model_type="$(jq -r '.model_type' "$l_model_path/config.json")"
    if [ "$l_model_type" = "deepseek_v3" ]; then
        echo "deepseek-v3"
    elif [ "$l_model_type" = "deepseek_v32" ]; then
        echo "deepseek-v3.2"
    elif [ "$l_model_type" = "glm_moe_dsa" ]; then
        echo "glm-5"
    elif [ "$l_model_type" = "minimax_m2" ]; then
        echo "minimax-m2"
    elif [ "$l_model_type" = "qwen3_5_moe" ] || [ "$l_model_type" = "qwen3_5_moe_text" ]; then
        echo "qwen-3.5"
    elif [ "$l_model_type" = "mimo_v2_flash" ]; then
        echo "mimo-v2-flash"
    elif [ "$l_model_type" = "deepseek_v4" ]; then
        echo "deepseek-v4-flash"
    else
        return 1
    fi
}

resolve_model_path() {
    local -r l_backend="$1"
    local -r l_model_spec="$2"
    local l_model_path=""
    local l_model_config=""
    if [ -z "$l_backend" ] || [ -z "$l_model_spec" ]; then
        echo "Error: Backend and model specification must be provided." >&2
        return 1
    elif [ -d "$l_model_spec" ] && [ -f "$l_model_spec/config.json" ]; then
        # 指定模型路径
        l_model_path="$l_model_spec"
    elif [ -f "$l_model_spec" ] && [ "$(basename "$l_model_spec")" = "config.json" ]; then
        # 指定模型 config.json 文件
        l_model_path="$(dirname "$l_model_spec")"
    elif [ -f "$l_model_spec" ] && [[ "$l_model_spec" = *".sh" ]]; then
        # 指定脚本里的模型配置文件, 只要是可访问的路径即可
        l_model_config="$l_model_spec"
    elif [ -f "$_utils_utils_sh_project_dir/$l_model_spec" ]; then
        # 指定脚本里的模型配置文件, 相对项目路径
        l_model_config="$_utils_utils_sh_project_dir/$l_backend/models/$l_model_spec"
    elif [ -f "$_utils_utils_sh_project_dir/$l_backend/$l_model_spec" ]; then
        # 指定脚本里的模型配置文件, 相对项目后端路径
        l_model_config="$_utils_utils_sh_project_dir/$l_backend/$l_model_spec"
    elif [ -f "$_utils_utils_sh_project_dir/$l_backend/models/$l_model_spec" ]; then
        # 指定脚本里的模型配置文件, 只有模型配置文件名
        l_model_config="$_utils_utils_sh_project_dir/$l_backend/models/$l_model_spec"
    elif [ -f "$_utils_utils_sh_project_dir/$l_backend/models/${l_model_spec}.sh" ]; then
        # 指定脚本里的模型配置文件, 只有模型配置文件名且没有带 .sh 后缀
        l_model_config="$_utils_utils_sh_project_dir/$l_backend/models/${l_model_spec}.sh"
    else
        echo "Error: Model specification '$l_model_spec' could not be resolved to a valid model path or config." >&2
        return 1
    fi

    [ -n "$l_model_config" ] && {
        # shellcheck source=../sglang/models/deepseek-v3.sh
        l_model_path="$(source "$l_model_config" && echo "$model_path_specific")"
    }

    [ -n "$l_model_path" ] || {
        echo "Error: Model path could not be resolved from specification '$l_model_spec'." >&2
        return 1
    }
    echo "$l_model_path"
}

table_lookup() {
    local -r l_table="$1"
    local l_key="$2"
    shift 2
    local -r l_fields=("$@")
    if [ "$l_key" = "number" ]; then
        l_key='\d+(\.\d*)?'
    fi
    local l_filter=""
    l_filter="$(printf '\s*,\s*%s' "${l_fields[@]}")"
    l_filter="${l_filter//./\\.}"
    # shellcheck disable=SC2016
    l_filter='print $1 if /^\s*('"$l_key"')'"$l_filter"'\s*(#|$)/'
    local l_res=""
    l_res="$(echo "$l_table" | perl -nle "$l_filter")"
    [ "$(echo "$l_res" | grep -c .)" -eq 1 ] || log_fatal "Table lookup failed for key '$l_key' with fields '${l_fields[*]}' in table: $l_table" "${BASH_SOURCE[1]}" "${BASH_LINENO[0]}"
    echo "$l_res"
}
