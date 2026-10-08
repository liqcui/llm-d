# shellcheck shell=bash
# shellcheck disable=SC2034

_sglang_tmux_config_sh_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_sglang_tmux_config_sh_project_dir="$(dirname "$_sglang_tmux_config_sh_script_dir")"
readonly _sglang_tmux_config_sh_script_dir _sglang_tmux_config_sh_project_dir

readonly container_engine="docker" # 可选 docker, nerdctl
readonly container_script_dir="$_sglang_tmux_config_sh_project_dir" # 容器内这个项目的目录
readonly my_log_base_dir="/metax0402/metax0402/lgao/dsv4-pd-log-flash/" # 本机路径，非容器路径
readonly my_service_profile_base_dir="/metax0402/metax0402/lgao/dsv4-pd-log/profile/" # 容器路径，非本机路径
readonly image="/metax0402/metax0402/lgao/sglang-ep-0.5.12-maca.ai3.7.1.110-dsv4-torch2.8-py310-ubuntu22.04-amd64.tar" #sglang-ep-smem32k-0.5.12-maca.ai3.7.1.104-dsv4-torch2.8-py310-ubuntu22.04-amd64.tar
readonly image_name="sglang-ep:0.5.12-maca.ai3.7.1.110-dsv4-torch2.8-py310-ubuntu22.04-amd64"

readonly container_name="sglang-dsv4-110-perf"
readonly task_session_name="sglang-dsv4-110-perf"

readonly node_client="192.168.8.25"
readonly node_minilb="192.168.8.25"
# readonly node_store="10.200.119.26"

readonly task_decode=(
    "decode"
    "./decode.sh"
    # 192.168.8.35
    # 192.168.8.40
    # 192.168.9.8
    # 192.168.9.10
    # 192.168.9.12
    # 192.168.9.14
    # 192.168.9.16
    # 192.168.9.18
    # 192.168.9.20
    # 192.168.9.22
    # 192.168.9.24
    192.168.9.26
    192.168.9.28
    # 192.168.9.30
    #192.168.9.35
    # 192.168.9.37
    # 192.168.9.41
)

readonly task_prefill=(
    "prefill"
    "./prefill.sh"
    192.168.8.25
    # 192.168.8.4
    # 192.168.8.6
    # 192.168.8.8
    # 192.168.8.10
    # 192.168.8.12

)

# readonly task_prefill_1=(
#     "prefill-1"
#     "./prefill.sh"
#      192.168.8.4
#     # 192.168.8.14
#     # 192.168.8.16
#     # 192.168.8.18
#     # 192.168.8.23
#     # 192.168.8.25
#     # 192.168.8.28
# )

# readonly task_prefill_2=(
#     "prefill-2"
#     "./prefill.sh"
#     192.168.8.6
# )

# readonly task_prefill_3=(
#     "prefill-3"
#     "./prefill.sh"
#     192.168.8.8
# )
# readonly task_prefill_4=(
#     "prefill-4"
#     "./prefill.sh"
#     192.168.8.10
# )

# readonly task_prefill_5=(
#     "prefill-5"
#     "./prefill.sh"
#     192.168.8.12
# )

# readonly task_prefill_6=(
#     "prefill-6"
#     "./prefill.sh"
#     192.168.8.14
# )

# readonly task_prefill_7=(
#     "prefill-7"
#     "./prefill.sh"
#     192.168.8.16
# )
# readonly task_prefill_8=(
#     "prefill-8"
#     "./prefill.sh"
#     192.168.8.18
# )


# readonly task_prefill_9=(
#     "prefill-9"
#     "./prefill.sh"
#     192.168.9.28
# )

# readonly task_prefill_10=(
#     "prefill-10"
#     "./prefill.sh"
#     192.168.8.23
# )
# readonly task_prefill_11=(
#     "prefill-11"
#     "./prefill.sh"
#     192.168.8.25
# )
# readonly task_prefill_12=(
#     "prefill-12"
#     "./prefill.sh"
#     192.168.8.28
# )

# readonly task_prefill_13=(
#     "prefill-13"
#     "./prefill.sh"
#     192.168.8.30
# )

# readonly task_prefill_14=(
#     "prefill-14"
#     "./prefill.sh"
#     192.168.8.33
# )

# readonly task_prefill_15=(
#     "prefill-15"
#     "./prefill.sh"
#     192.168.8.35
# )


# readonly task_prefill_16=(
#     "prefill-16"
#     "./prefill.sh"
#     192.168.8.37
# )


# readonly task_prefill_17=(
#     "prefill-17"
#     "./prefill.sh"
#     192.168.8.40
# )
# readonly task_prefill_18=(
#     "prefill-18"
#     "./prefill.sh"
#     192.168.9.8
# )

# readonly task_prefill_19=(
#     "prefill-19"
#     "./prefill.sh"
#     192.168.9.10
# )

# readonly task_prefill_20=(
#     "prefill-20"
#     "./prefill.sh"
#     192.168.9.12
# )

# readonly task_prefill_21=(
#     "prefill-21"
#     "./prefill.sh"
#     192.168.9.14
# )
# readonly task_prefill_22=(
#     "prefill-22"
#     "./prefill.sh"
#     192.168.9.16
# )


# readonly task_prefill_23=(
#     "prefill-23"
#     "./prefill.sh"
#     192.168.9.18
# )

# readonly task_prefill_24=(
#     "prefill-24"
#     "./prefill.sh"
#     192.168.9.20
# )
# readonly task_prefill_25=(
#     "prefill-25"
#     "./prefill.sh"
#     192.168.9.22
# )
# readonly task_prefill_26=(
#     "prefill-26"
#     "./prefill.sh"
#     192.168.9.24
# )

# readonly task_prefill_27=(
#     "prefill-27"
#     "./prefill.sh"
#     192.168.9.26
# )

# readonly task_prefill_28=(
#     "prefill-28"
#     "./prefill.sh"
#     192.168.9.35
# )

# readonly task_prefill_29=(
#     "prefill-29"
#     "./prefill.sh"
#     192.168.9.30
# )
