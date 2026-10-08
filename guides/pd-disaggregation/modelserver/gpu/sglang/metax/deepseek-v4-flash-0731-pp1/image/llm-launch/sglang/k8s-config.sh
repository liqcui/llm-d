# shellcheck shell=bash

readonly prefill_instance=1 # prefill 实例数量
readonly decode_instance=1  # decode 实例数量
readonly prefill_nnodes=2   # 每个 prefill 实例的节点数量
readonly decode_nnodes=4    # 每个 decode 实例的节点数量

readonly container_project_root_dir="/bgfs/mxtz/projects/llm-launch" # 容器内这个脚本项目的路径
readonly my_log_base_dir="/bgfs/mxtz/output/log/sglang" # 容器内保存日志的路径
readonly my_service_profile_base_dir="/bgfs/mxtz/output/profile/sglang" # 容器内采集 Profile 保存的路径
readonly image="/bgfs/images/sglang/sglang-maca-250822-deepep-250917-mcoplib-0923-stepmesh-0.0.1.dev0.tar"

readonly k8s_namespace="metax-ai-pd"
