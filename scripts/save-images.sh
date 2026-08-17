#!/usr/bin/env bash
# ==============================================================================
# llm-d Docker 镜像离线保存脚本 (Save)
# ==============================================================================
# 在联网机器上运行，拉取部署 llm-d 所需的所有 Docker 镜像并保存为 tar 文件。
#
# 用法:
#   ./scripts/save-images.sh [OPTIONS]
#
# 选项:
#   -o, --output-dir DIR    输出目录 (默认: ./docker-images)
#   --platform PLATFORM      目标平台: cuda, rocm, cpu, xpu, all (默认: cuda)
#   --include-observability  包含 Prometheus/Grafana/Jaeger/OTEL 监控镜像
#   --include-benchmark      包含 benchmark 测试镜像
#   --include-envoy          包含 Envoy 网关镜像 (非 K8s 部署)
#   --include-all            包含所有可选镜像
#   --no-llm-d               跳过 llm-d 自建镜像 (仅拉取第三方镜像)
#   -h, --help               显示帮助
#
# 输出:
#   每个镜像保存为 <image-name>_<tag>.tar (docker save 格式)
#   生成 MANIFEST.txt 和 load-images.sh 脚本
# ==============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# 默认值
# ---------------------------------------------------------------------------
OUTPUT_DIR="./docker-images"
PLATFORM="cuda"
INCLUDE_OBSERVABILITY=false
INCLUDE_BENCHMARK=false
INCLUDE_ENVOY=false
INCLUDE_ALL=false
SKIP_LLMD=false

# ---------------------------------------------------------------------------
# 解析参数
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        --platform)
            PLATFORM="$2"; shift 2 ;;
        --include-observability)
            INCLUDE_OBSERVABILITY=true; shift ;;
        --include-benchmark)
            INCLUDE_BENCHMARK=true; shift ;;
        --include-envoy)
            INCLUDE_ENVOY=true; shift ;;
        --include-all)
            INCLUDE_ALL=true; shift ;;
        --no-llm-d)
            SKIP_LLMD=true; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# //'
            exit 0 ;;
        *)
            echo "未知选项: $1"
            exit 1 ;;
    esac
done

if $INCLUDE_ALL; then
    INCLUDE_OBSERVABILITY=true
    INCLUDE_BENCHMARK=true
    INCLUDE_ENVOY=true
fi

CONTAINER_TOOL=$(command -v docker >/dev/null 2>&1 && echo "docker" || echo "")
if [ -z "$CONTAINER_TOOL" ]; then
    CONTAINER_TOOL=$(command -v podman >/dev/null 2>&1 && echo "podman" || echo "")
fi
if [ -z "$CONTAINER_TOOL" ]; then
    echo "错误: 未找到 docker 或 podman，请先安装。"
    exit 1
fi

mkdir -p "${OUTPUT_DIR}"

# ---------------------------------------------------------------------------
# 镜像定义
# ---------------------------------------------------------------------------
# 格式: "镜像全名:tag|类别|说明"

declare -a ALL_IMAGES=()

# ============================================================
# 1. llm-d 核心镜像 (由 llm-d CI 构建，推送到 ghcr.io)
# ============================================================
LLMD_VERSION="v0.7.0"

declare -a LLMD_CUDA_IMAGES=(
    "ghcr.io/llm-d/llm-d-cuda:${LLMD_VERSION}|llm-d|llm-d CUDA 模型服务器镜像 (默认 GPU)"
)
declare -a LLMD_ROCM_IMAGES=(
    "ghcr.io/llm-d/llm-d-rocm:${LLMD_VERSION}|llm-d|llm-d ROCm 模型服务器镜像 (AMD GPU)"
)
declare -a LLMD_CPU_IMAGES=(
    "ghcr.io/llm-d/llm-d-cpu:${LLMD_VERSION}|llm-d|llm-d CPU 模型服务器镜像"
)
declare -a LLMD_XPU_IMAGES=(
    "ghcr.io/llm-d/llm-d-xpu:${LLMD_VERSION}|llm-d|llm-d Intel XPU 模型服务器镜像"
)

# ============================================================
# 2. llm-d Router 镜像
# ============================================================
ROUTER_EPP_VERSION="v0.9.0"
ROUTER_SIDECAR_VERSION="v0.9.1"

declare -a ROUTER_IMAGES=(
    "ghcr.io/llm-d/llm-d-router-endpoint-picker:${ROUTER_EPP_VERSION}|router|llm-d EPP (Endpoint Picker) 路由核心"
    "ghcr.io/llm-d/llm-d-router-disagg-sidecar:${ROUTER_SIDECAR_VERSION}|router|llm-d P/D 分离路由 Sidecar"
)

# Mooncake KV Store (用于 wide-ep 多节点部署)
declare -a MOONCAKE_IMAGES=(
    "ghcr.io/llm-d/mooncake-master-store:v0.8.0|router|Mooncake KV Store (多节点 KV 缓存)"
)

# ============================================================
# 3. 上游模型服务器镜像 (默认值，可按需覆盖)
# ============================================================
declare -a MODEL_SERVER_IMAGES=(
    "docker.io/vllm/vllm-openai:v0.23.0|model-server|vLLM OpenAI 兼容服务器 (默认 GPU)"
)

# 其他模型服务器 (按需启用: --include-all 或手动取消注释)
declare -a EXTRA_MODEL_SERVER_IMAGES=(
    "docker.io/vllm/vllm-openai-cpu:v0.23.0|model-server|vLLM CPU 模型服务器"
    "docker.io/vllm/vllm-tpu:v0.22.0|model-server|vLLM TPU 模型服务器"
    "docker.io/lmsysorg/sglang:v0.5.13.post1|model-server|SGLang GPU 模型服务器"
    "docker.io/lmsysorg/sglang:v0.5.13.post1-rocm720-mi30x|model-server|SGLang AMD ROCm 模型服务器"
    "nvcr.io/nvidia/tensorrt-llm/release:1.3.0rc18|model-server|TensorRT-LLM 模型服务器"
)

# ============================================================
# 4. Envoy 网关 (非 K8s 部署 / 独立模式)
# ============================================================
declare -a ENVOY_IMAGES=(
    "docker.io/envoyproxy/envoy:distroless-v1.33.2|gateway|Envoy 代理 (独立/非 K8s 部署)"
)

# ============================================================
# 5. 可观测性 (Prometheus / Grafana / Jaeger / OTEL)
# ============================================================
declare -a OBSERVABILITY_IMAGES=(
    "quay.io/prometheus/prometheus:v2.54.1|observability|Prometheus 监控"
    "ghcr.io/open-telemetry/opentelemetry-collector-releases/opentelemetry-collector-contrib:0.120.0|observability|OpenTelemetry Collector"
    "jaegertracing/jaeger:2.15.0|observability|Jaeger 分布式追踪"
)

# ============================================================
# 6. GAIE 延迟预测 Sidecar (用于 predicted-latency-routing)
# ============================================================
declare -a GAIE_IMAGES=(
    "registry.k8s.io/gateway-api-inference-extension/latency-training-server:v1.5.0|gaie|GAIE 延迟模型训练 Server"
    "registry.k8s.io/gateway-api-inference-extension/latency-prediction-server:v1.5.0|gaie|GAIE 延迟预测 Server"
)

# ============================================================
# 7. Benchmark 测试镜像
# ============================================================
declare -a BENCHMARK_IMAGES=(
    "ghcr.io/llm-d/llm-d-benchmark:v0.7.0|benchmark|llm-d Benchmark 测试工具"
    "quay.io/inference-perf/inference-perf:v0.6.0|benchmark|K8s Inference Perf 基准测试"
)

# ============================================================
# 8. 其他辅助 / Init Container / Debug 镜像
# ============================================================
declare -a AUX_IMAGES=(
    "python:3.11-slim|aux|Python 运行环境 (校准任务等)"
    "busybox:latest|aux|Init Container (TPU 节点初始化等)"
    "alpine:3.20|aux|健康检查 Job"
    "docker.io/cfmanteiga/alpine-bash-curl-jq:latest|aux|Debug/curl 测试 Pod (所有 guide 通用)"
)

# ---------------------------------------------------------------------------
# 组装最终镜像列表
# ---------------------------------------------------------------------------
IMAGES=()

# 根据平台添加 llm-d 核心镜像
if ! $SKIP_LLMD; then
    case "$PLATFORM" in
        cuda)
            IMAGES+=("${LLMD_CUDA_IMAGES[@]}") ;;
        rocm)
            IMAGES+=("${LLMD_ROCM_IMAGES[@]}") ;;
        cpu)
            IMAGES+=("${LLMD_CPU_IMAGES[@]}") ;;
        xpu)
            IMAGES+=("${LLMD_XPU_IMAGES[@]}") ;;
        all)
            IMAGES+=("${LLMD_CUDA_IMAGES[@]}")
            IMAGES+=("${LLMD_ROCM_IMAGES[@]}")
            IMAGES+=("${LLMD_CPU_IMAGES[@]}")
            IMAGES+=("${LLMD_XPU_IMAGES[@]}") ;;
        *)
            echo "未知平台: ${PLATFORM}，可选值: cuda, rocm, cpu, xpu, all"
            exit 1 ;;
    esac
fi

# Router 镜像总是需要
IMAGES+=("${ROUTER_IMAGES[@]}")

# 模型服务器 (默认镜像)
IMAGES+=("${MODEL_SERVER_IMAGES[@]}")

# Mooncake (仅 --include-all 时)
if $INCLUDE_ALL; then
    IMAGES+=("${MOONCAKE_IMAGES[@]}")
fi

# 可选镜像
if $INCLUDE_ENVOY; then
    IMAGES+=("${ENVOY_IMAGES[@]}")
fi
if $INCLUDE_OBSERVABILITY; then
    IMAGES+=("${OBSERVABILITY_IMAGES[@]}")
fi
if $INCLUDE_BENCHMARK; then
    IMAGES+=("${BENCHMARK_IMAGES[@]}")
fi

# 辅助镜像 (总是包含，很小)
IMAGES+=("${AUX_IMAGES[@]}")

# 额外模型服务器镜像 (仅 --include-all 时)
if $INCLUDE_ALL; then
    IMAGES+=("${EXTRA_MODEL_SERVER_IMAGES[@]}")
    IMAGES+=("${GAIE_IMAGES[@]}")
fi

# ---------------------------------------------------------------------------
# 显示摘要
# ---------------------------------------------------------------------------
echo ""
echo "=============================================================================="
echo "  llm-d Docker 镜像离线保存"
echo "=============================================================================="
echo "  平台:            ${PLATFORM}"
echo "  容器工具:        ${CONTAINER_TOOL}"
echo "  镜像数量:        ${#IMAGES[@]}"
echo "  输出目录:        ${OUTPUT_DIR}"
echo "  含可观测性镜像:  ${INCLUDE_OBSERVABILITY}"
echo "  含 Benchmark:    ${INCLUDE_BENCHMARK}"
echo "  含 Envoy:        ${INCLUDE_ENVOY}"
echo "=============================================================================="

# ---------------------------------------------------------------------------
# 拉取并保存每个镜像
# ---------------------------------------------------------------------------
MANIFEST="${OUTPUT_DIR}/MANIFEST.txt"
LOAD_SCRIPT="${OUTPUT_DIR}/load-images.sh"

echo "# llm-d Docker 镜像清单 - $(date '+%Y-%m-%d %H:%M:%S')" > "${MANIFEST}"
echo "# 平台: ${PLATFORM}" >> "${MANIFEST}"
echo "# 格式: tar_file | image:tag | 类别 | 说明" >> "${MANIFEST}"
echo "" >> "${MANIFEST}"

# 生成 load-images.sh 头部
cat > "${LOAD_SCRIPT}" << 'LOAD_HEADER'
#!/usr/bin/env bash
# ==============================================================================
# llm-d Docker 镜像离线加载脚本 (Load)
# ==============================================================================
# 在离线机器上运行，加载之前保存的 Docker 镜像 tar 文件。
#
# 用法:
#   ./load-images.sh [OPTIONS]
#
# 选项:
#   -d, --images-dir DIR    镜像 tar 文件所在目录 (默认: 当前目录)
#   -r, --registry URL      推送到私有仓库 (如: my-registry.com:5000/llm-d)
#   --retag-only            只重新打 tag 到私有仓库，不 push
#   -h, --help              显示帮助
# ==============================================================================

set -Eeuo pipefail

IMAGES_DIR="."
REGISTRY=""
RETAG_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -d|--images-dir)
            IMAGES_DIR="$2"; shift 2 ;;
        -r|--registry)
            REGISTRY="$2"; shift 2 ;;
        --retag-only)
            RETAG_ONLY=true; shift ;;
        -h|--help)
            sed -n '2,24p' "$0" | sed 's/^# //'
            exit 0 ;;
        *)
            echo "未知选项: $1"
            exit 1 ;;
    esac
done

CONTAINER_TOOL=$(command -v docker >/dev/null 2>&1 && echo "docker" || echo "")
if [ -z "$CONTAINER_TOOL" ]; then
    CONTAINER_TOOL=$(command -v podman >/dev/null 2>&1 && echo "podman" || echo "")
fi
if [ -z "$CONTAINER_TOOL" ]; then
    CONTAINER_TOOL=$(command -v ctr >/dev/null 2>&1 && echo "ctr" || echo "")
fi
if [ -z "$CONTAINER_TOOL" ]; then
    CONTAINER_TOOL=$(command -v crictl >/dev/null 2>&1 && echo "crictl" || echo "")
fi
if [ -z "$CONTAINER_TOOL" ]; then
    echo "错误: 未找到容器运行时 (docker/podman/ctr/crictl)"
    exit 1
fi

echo ""
echo "=============================================================================="
echo "  llm-d Docker 镜像离线加载"
echo "=============================================================================="
echo "  容器工具:      ${CONTAINER_TOOL}"
echo "  镜像目录:      ${IMAGES_DIR}"
echo "  私有仓库:      ${REGISTRY:-无 (仅本地加载)}"
echo "=============================================================================="

LOAD_HEADER

# 赋予 load 脚本执行权限
chmod +x "${LOAD_SCRIPT}"

FAILED=()
SUCCESS_COUNT=0

for img_def in "${IMAGES[@]}"; do
    IFS='|' read -r image category desc <<< "${img_def}"

    # 生成安全的文件名: 把 / 和 : 替换为 _
    safe_name=$(echo "${image}" | sed 's/[\/:]/_/g')
    tar_file="${safe_name}.tar"
    tar_path="${OUTPUT_DIR}/${tar_file}"

    echo ""
    echo "=============================================================================="
    echo "[$(date '+%H:%M:%S')] ${image}"
    echo "  类别: ${category}"
    echo "  说明: ${desc}"
    echo "=============================================================================="

    if [ -f "${tar_path}" ]; then
        echo "  => tar 已存在，跳过拉取: ${tar_file}"
    else
        echo "  => 拉取镜像..."
        if ${CONTAINER_TOOL} pull "${image}"; then
            echo "  => 保存为 tar: ${tar_file}"
            ${CONTAINER_TOOL} save -o "${tar_path}" "${image}"
            local_size=$(du -h "${tar_path}" | cut -f1)
            echo "  => 完成 (${local_size})"
        else
            echo "  *** 拉取失败: ${image} ***"
            FAILED+=("${image}")
            continue
        fi
    fi

    # 写入 MANIFEST
    echo "${tar_file} | ${image} | ${category} | ${desc}" >> "${MANIFEST}"

    # 写入 load-images.sh 加载命令
    cat >> "${LOAD_SCRIPT}" << LOAD_ENTRY
echo "加载: ${image}"
if [ -f "\${IMAGES_DIR}/${tar_file}" ]; then
    ${CONTAINER_TOOL} load -i "\${IMAGES_DIR}/${tar_file}"
LOAD_ENTRY

    if [ -n "${REGISTRY}" ]; then
        # 提取镜像名 (去掉 registry 部分)
        image_name_tag=$(echo "${image}" | sed 's|^docker.io/||; s|^quay.io/||; s|^ghcr.io/||; s|^nvcr.io/||; s|^public.ecr.aws/||')
        new_image="${REGISTRY}${image_name_tag}"
        cat >> "${LOAD_SCRIPT}" << LOAD_RETAG
    if [ -n "${REGISTRY}" ]; then
        echo "  重新打 tag: ${new_image}"
        ${CONTAINER_TOOL} tag "${image}" "${new_image}"
        if ! ${RETAG_ONLY}; then
            echo "  推送到私有仓库..."
            ${CONTAINER_TOOL} push "${new_image}"
        fi
    fi
LOAD_RETAG
    fi

    cat >> "${LOAD_SCRIPT}" << LOAD_END
else
    echo "  *** 未找到文件: \${IMAGES_DIR}/${tar_file} ***"
fi

LOAD_END

    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
done

# ---------------------------------------------------------------------------
# 完成 load-images.sh
# ---------------------------------------------------------------------------
cat >> "${LOAD_SCRIPT}" << 'LOAD_FOOTER'

echo ""
echo "=============================================================================="
echo "  镜像加载完成!"
echo "=============================================================================="
echo "  验证: ${CONTAINER_TOOL} images | grep -E 'ghcr.io/llm-d|vllm/vllm-openai'"
echo "=============================================================================="
LOAD_FOOTER

# ---------------------------------------------------------------------------
# 总结
# ---------------------------------------------------------------------------
echo ""
echo "=============================================================================="
echo "  保存完成!"
echo "=============================================================================="
echo "  总计:    ${#IMAGES[@]} 个镜像"
echo "  成功:    ${SUCCESS_COUNT}"
echo "  失败:    ${#FAILED[@]}"
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "  失败列表:"
    for f in "${FAILED[@]}"; do
        echo "    - ${f}"
    done
fi
echo "  输出目录: ${OUTPUT_DIR}"
echo "  总大小:   $(du -sh "${OUTPUT_DIR}" | cut -f1)"
echo "  清单文件: ${MANIFEST}"
echo "  加载脚本: ${LOAD_SCRIPT}"
echo ""
echo "  ==== 离线部署步骤 ===="
echo "  1. 将 ${OUTPUT_DIR}/ 整个目录拷贝到离线机器"
echo "  2. 在离线机器上运行: cd ${OUTPUT_DIR} && ./load-images.sh"
echo "  3. (可选) 推送到私有仓库:"
echo "     ./load-images.sh -r my-registry.com:5000/llm-d"
echo "=============================================================================="

exit ${#FAILED[@]}
