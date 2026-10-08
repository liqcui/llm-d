readonly my_log_base_dir="/bgfs/mxtz/output/log/vllm"
readonly image="/bgfs/images/vllm/vllm-maca-250822-deepep-250917-mcoplib-0923-stepmesh-0.0.1.dev0.tar"
readonly image_name="localhost/vllm:maca-250822-deepep-250917-mcoplib-0923-stepmesh-0.0.1.dev0"
readonly container_name="pde-ai-vllm"
readonly session_name="pde-ai-vllm"

readonly node_minilb="10.200.119.121"
readonly node_client="10.200.119.121"

# shellcheck disable=SC2034
readonly task_decode=(
    "decode"
    "./decode.sh"
    10.200.119.57
    10.200.119.117
    10.200.119.118
    10.200.119.4
)

# shellcheck disable=SC2034
readonly task_prefill=(
    "prefill"
    "./prefill.sh"
    10.200.119.121
    10.200.119.119
)

# readonly task_prefill_2=(
#     "prefill-2"
#     "./prefill.sh"
#     10.130.71.8
#     10.130.71.7
# )
