# shellcheck shell=bash
[ -n "${_utils_error_sh_script_dir:-}" ] && return 0

export LLM_LAUNCH_ENV="release"
export TIMEFORMAT="%Rs total %Us user %Ss system %P%% cpu"
export LC_ALL="C.UTF-8"

_utils_error_sh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_utils_error_sh_project_dir="$(dirname "$_utils_error_sh_script_dir")"

log_print_inner() {
    local -r l_level="$1"
    local -r l_msg="$2"
    local -r l_file="$(realpath -m --relative-to="$_utils_error_sh_project_dir" "${3:-${BASH_SOURCE[2]}}")"
    local -r l_line="${4:-${BASH_LINENO[1]}}"
    echo "$l_level: $l_msg (at $l_file:$l_line)" >&2
}

log_warn() {
    log_print_inner "Warn" "$@"
}

log_error() {
    log_print_inner "Error" "$@"
}

log_fatal() {
    local -r ec="$?"
    log_print_inner "Fatal" "$@"
    exit "$ec"
}

get_parent_file() {
    echo "${BASH_SOURCE[2]}"
}

get_parent_line() {
    echo "${BASH_LINENO[1]}"
}

[ -n "${BASH_VERSION:-}" ] && [ -z "$(trap -p ERR)" ] && trap 'log_fatal "$BASH_COMMAND, exit: $?"' ERR
