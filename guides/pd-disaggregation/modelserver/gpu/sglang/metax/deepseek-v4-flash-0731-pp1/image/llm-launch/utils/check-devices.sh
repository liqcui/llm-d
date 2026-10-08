#!/bin/bash

set -euE
shopt -s inherit_errexit

[ "$#" -eq 2 ] || [ "$#" -eq 3 ] || {
    echo "Usage: $0 driver|bios|ib|process [kill] [devices list file]" >&2
    exit 1
}

readonly method="$1"
readonly devices_file="${!#}"

readonly timeout_connect=${MY_CHECK_DEVICES_TIMEOUT_CONNECT:-1}
readonly timeout_exec_cmd=${MY_CHECK_DEVICES_TIMEOUT_EXEC_CMD:-60}

[ -r "$devices_file" ] || {
    echo "Devices list file '$devices_file' not found" >&2
    exit 1
}

# shellcheck disable=SC2016
cmd_smi='"$(command -v ht-smi || command -v mx-smi || command -v nvidia-smi || echo echo)"'

highlight_version() {
    versions="$(sort <<< "$1" | uniq -c)"
    [ "$(wc -l <<< "$versions")" -le 1 ] && {
        echo '^none$'
        return
    }
    regex="$(sort -n <<< "$versions" | head -n -1 | awk '{print $2}' | xargs | sed -e 's/\./\\./g' -e 's/ /|/g')"
    echo '((?<=\s)('"$regex"')((?=\D)|$))'
}

get_devices() {
    grep -v '^\s*#' "$devices_file" | sed 's/^\s*\|\s*$//g'
}

check_cmd() {
    local -r l_cmd="$1"
    local -r l_env_cmd="${MY_CHECK_DEVICES_CMD:-}"
    [ "$l_env_cmd" = "$l_cmd" ] || [ -z "$l_env_cmd" ] && command -v "$l_cmd" >/dev/null
}

if check_cmd "pdsh"; then
    echo "Using pdsh"
    batch_ssh() {
        env PDSH_SSH_ARGS_APPEND="-o StrictHostKeyChecking=no" pdsh -SR ssh -t "$timeout_connect" -u "$timeout_exec_cmd" -w - "$@"
    }
elif check_cmd "ssh"; then
    echo "Using ssh"
    echo "Using pdsh is faster when there are many machines."
    batch_ssh_helper() {
        local l_device="$1"
        local l_args=("${@:2}")
        # shellcheck disable=SC2029
        (
            timeout "$timeout_exec_cmd" ssh -o StrictHostKeyChecking=no -o ConnectTimeout="$timeout_connect" "$l_device" "${l_args[@]}" || {
                exit_code=$?
                [ "$exit_code" -eq 124 ] && echo "$l_device: command timeout" >&2 && exit 0
                [ "$exit_code" -eq 255 ] && echo "$l_device: connect timeout" >&2 && exit 0
                exit "$exit_code"
            }
        ) | while IFS= read -r line; do echo "$l_device: $line"; done
        [ "${PIPESTATUS[0]}" -eq 0 ] || {
            echo "$l_device: ssh command failed with exit code ${PIPESTATUS[0]}" >&2
            kill -SIGTERM 0
        }
    }
    batch_ssh() {
        local l_device l_devices
        readarray -t l_devices < <(cat)
        for l_device in "${l_devices[@]}"; do
            batch_ssh_helper "$l_device" "$@" &
        done
        wait
    }
else
    echo "No suitable command found for batch SSH (pdsh or ssh)"
    exit 1
fi

# shellcheck disable=SC2016
readonly awk_parse_smi="awk '"'
    {
        if ($0 ~ /Process/) {
            flag = 1;
        } else if (flag == 1 && $0 ~ /====/) {
            flag = 2;
        } else if (flag == 2 && ($0 ~ /----/ || $0 ~ /no process found/)) {
            flag = 3;
        } else if (flag == 0) {
            if (match($0, / [0-9]+% /)) {
                matched_str = substr($0, RSTART, RLENGTH);
                gsub(/[^0-9]/, "", matched_str);
                usage += matched_str;
                usage_gpu_count += 1;
            }
            if (match($0, / [0-9]+(\/|MiB \/ )[0-9]+(MiB)? /)) {
                matched_str = substr($0, RSTART, RLENGTH);
                match(matched_str, /[0-9]+/)
                mem += substr(matched_str, RSTART, RLENGTH)
                rest = substr(matched_str, RSTART + RLENGTH)
                match(rest, /[0-9]+/)
                mem_total += substr(rest, RSTART, RLENGTH)
                mem_gpu_count += 1;
            }
        } else if (flag == 2 && $0 !~ /xorg\/Xorg/) {
            process_count += 1;
        }
    }
    END {
        if (usage_gpu_count != mem_gpu_count) {
            printf "Inconsistent GPU count for Usage(%d) and Memory(%d) usage\n", usage_gpu_count, mem_gpu_count > "/dev/stderr";
        }
        printf "gpus: %d, process: %s, usage: %d%%(%.1f%%), memory: %d MiB(%.2f%%)\n",  \
            usage_gpu_count,                                                            \
            process_count,                                                              \
            usage,                                                                      \
            usage_gpu_count ? usage / usage_gpu_count : 0,                              \
            mem,                                                                        \
            mem_total ? mem * 100 / mem_total : 0
        ;
    }
'"'"
show-process() {
    local -r remote_cmd="$(echo "$cmd_smi 2>&1 | $awk_parse_smi" | base64 | tr -d '\n')"
    get_devices | batch_ssh "echo $remote_cmd | base64 -d | bash" | column -t | sort -V
    return "$(printf "%s\n" "${PIPESTATUS[@]}" | grep -m1 -vP '^0$' || echo 0)"
}

case "$method" in
    bios | driver)
    res="$(get_devices | batch_ssh "$cmd_smi | grep -oP '(Driver|BIOS) Version: \S+' | xargs")"
    all_driver_version="$(awk '{print $4}' <<< "$res")"
    all_bios_version="$(awk '{print $7}' <<< "$res")"
    highlight_driver="$(highlight_version "$all_driver_version")"
    highlight_bios="$(highlight_version "$all_bios_version")"
    column -t <<< "$res" | sort -V | grep --color=always -P "$highlight_driver|$highlight_bios|^"
    echo -e "Driver: $(sort -uV <<< "$all_driver_version" | xargs)\nBIOS: $(sort -uV <<< "$all_bios_version" | xargs)" | column -t
    ;;
    ib)
    get_devices | batch_ssh "/bgfs/mxtz/scripts/check-ib-devices.sh" | column -t | sort -V
    ;;
    process)
    show-process
    [ "$2" = "kill" ] && {
        echo
        get_devices | batch_ssh "$cmd_smi --kill-all-process 2>&1 | grep 'Done'" | sort -V
        echo
        show-process
    }
    true
    ;;
    *)
    echo "Usage $0 driver|bios|ib|process [devices list file]"
    exit 1
    ;;
esac
