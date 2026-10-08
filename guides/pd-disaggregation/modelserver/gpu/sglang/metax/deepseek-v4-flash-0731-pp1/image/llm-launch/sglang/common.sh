# shellcheck shell=bash

echo "$SHELL: $BASH_VERSION"

_sglang_common_sh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_sglang_common_sh_project_dir="$(dirname "$_sglang_common_sh_script_dir")"

_sglang_common_sh_model_spec="${1:-}"
pd_disaggregation_mode="${2:-}"

# sed -i 's@//.*.com@//mirrors.ustc.edu.cn@g' /etc/apt/sources.list

# shellcheck source=../utils/utils.sh
source "${_sglang_common_sh_project_dir}/utils/utils.sh"

check_commands ip

init_conda_python
set_env_filter

local_ip="$(get_local_ip)"
net_primary_iface="$(get_net_primary_iface)"
[[ "|prefill|decode|" = *"|${pd_disaggregation_mode:-}|"* ]] && {
    gpu_name="$(get_gpu_name)"
    num_dies="$(get_num_dies)"
    "$_sglang_common_sh_project_dir/utils/check-device-performance.sh"
}
readonly local_ip net_primary_iface gpu_name num_dies

model_path=""
[ -n "$_sglang_common_sh_model_spec" ] && model_path="$(resolve_model_path "sglang" "$_sglang_common_sh_model_spec")"

# pip config set global.index-url https://pypi.tuna.tsinghua.edu.cn/simple
readonly external_sources_path="" # 替换为自己的源码在容器内的路径，不配置使用容器内默认代码
[ -n "${external_sources_path:-}" ] && {
    if [ -d "$external_sources_path" ]; then
        pip show sglang | grep -P '[Ll]ocation' | grep " $external_sources_path$" || (
            cd "$external_sources_path" || return 1
            set -x
            pip install -e . --no-deps --no-index --no-build-isolation
        )
        export PYTHONPATH="$external_sources_path${PYTHONPATH:+:$PYTHONPATH}"
        echo "git commit id: $(get_git_commit_id "$external_sources_path/..")"
    elif [ "$LLM_LAUNCH_ENV" != "release" ]; then
        log_fatal "External sources path '$external_sources_path' does not exist."
    fi
}

sglang_version="$(pip show sglang | grep -oP '(?<=^Version: )\d+\.\d+\.\d+')"
[ -n "$sglang_version" ] || log_fatal "Failed to get sglang version from pip show sglang"
sglang_version="v$sglang_version"
readonly sglang_version
echo "SGLang version: $sglang_version"
[ "$sglang_version" = "v0.5.1" ] || [ "$sglang_version" = "v0.5.7" ] || [ "$sglang_version" = "v0.5.8" ] || [ "$sglang_version" = "v0.5.12" ] || [ "$sglang_version" = "v0.5.13" ] || log_fatal "Unsupported SGLang version: $sglang_version"

source "$_sglang_common_sh_script_dir/config.sh" "$model_path" "$pd_disaggregation_mode"
