# shellcheck shell=bash
# shellcheck disable=SC2034

_sglang_tmux_config_sh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_sglang_tmux_config_sh_project_dir="$(dirname "$_sglang_tmux_config_sh_script_dir")"
readonly _sglang_tmux_config_sh_script_dir _sglang_tmux_config_sh_project_dir

readonly container_engine="nerdctl" # 可选 docker, nerdctl
readonly container_script_dir="$_sglang_tmux_config_sh_project_dir" # 容器内这个项目的目录
readonly my_log_base_dir="/bgfs/mxtz/output/log/deepep" # 本机路径，非容器路径
readonly image="/bgfs/images/sglang/sglang-0.5.7-maca.ai20260228-304-torch2.8-py310-build-0330-ubuntu22.04-amd64.tar"
readonly image_name="pub-registry1.metax-tech.com/ai-opentest/master/maca/sglang:0.5.7-maca.ai20260228-304-torch2.8-py310-build-0330-ubuntu22.04-amd64"

readonly container_name="pde-ai-sglang"
readonly task_session_name="pde-ai-sglang"

readonly task_deepep=(
    "deepep"
    "./low-latency.sh"
    10.200.119.119
    10.200.119.120
)
