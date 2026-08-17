#!/usr/bin/env bash
# ==============================================================================
# llm-d Repository Pull & Save Script
# ==============================================================================
# This script clones/pulls all repositories required to build/deploy llm-d
# and saves each as a tar.gz archive for offline deployment.
#
# Usage:
#   ./scripts/pull-and-save-repos.sh [OPTIONS]
#
# Options:
#   -o, --output-dir DIR    Output directory for tar archives (default: ./repos-tar)
#   -c, --clone-dir DIR     Directory to clone repos into (default: ./repos-src)
#   --cuda-only             Only pull CUDA-related repos (skip ROCM)
#   --rocm-only             Only pull ROCM-related repos (skip CUDA)
#   --core-only             Only pull core repos (vllm + essential deps, skip RDMA tools)
#   -h, --help              Show this help
#
# Output:
#   Each repo is saved as <repo-name>_<ref>.tar.gz in the output directory.
#   A manifest file listing all repos and their versions is also generated.
# ==============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
OUTPUT_DIR="./repos-tar"
CLONE_DIR="./repos-src"
CUDA_ONLY=false
ROCM_ONLY=false
CORE_ONLY=false

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -o|--output-dir)
            OUTPUT_DIR="$2"; shift 2 ;;
        -c|--clone-dir)
            CLONE_DIR="$2"; shift 2 ;;
        --cuda-only)
            CUDA_ONLY=true; shift ;;
        --rocm-only)
            ROCM_ONLY=true; shift ;;
        --core-only)
            CORE_ONLY=true; shift ;;
        -h|--help)
            sed -n '2,30p' "$0" | sed 's/^# //'
            exit 0 ;;
        *)
            echo "Unknown option: $1"
            exit 1 ;;
    esac
done

mkdir -p "${OUTPUT_DIR}" "${CLONE_DIR}"

# ---------------------------------------------------------------------------
# Helper functions
# ---------------------------------------------------------------------------
clone_and_tar() {
    local name="$1"
    local repo_url="$2"
    local ref="$3"
    local extra_args="${4:-}"

    local clone_path="${CLONE_DIR}/${name}"
    local tar_name="${name}_${ref//\//_}.tar.gz"
    local tar_path="${OUTPUT_DIR}/${tar_name}"

    echo ""
    echo "=============================================================================="
    echo "[$(date '+%H:%M:%S')] Processing: ${name}"
    echo "  Repo: ${repo_url}"
    echo "  Ref:  ${ref}"
    echo "=============================================================================="

    if [ -f "${tar_path}" ]; then
        echo "  => tar already exists, skipping: ${tar_path}"
        return 0
    fi

    if [ -d "${clone_path}/.git" ]; then
        echo "  => Repo already cloned, fetching updates..."
        git -C "${clone_path}" fetch --depth=1 origin "${ref}" 2>/dev/null || \
            git -C "${clone_path}" fetch origin "${ref}"
        git -C "${clone_path}" checkout "${ref}"
        # Clean up any stale build artifacts
        git -C "${clone_path}" clean -fdx 2>/dev/null || true
    else
        rm -rf "${clone_path}"
        echo "  => Cloning..."
        # shellcheck disable=SC2086
        git clone ${extra_args} --branch "${ref}" "${repo_url}" "${clone_path}" || {
            # If branch checkout fails (e.g. it's a SHA), try full clone + checkout
            echo "  => Branch clone failed, trying full clone + checkout..."
            rm -rf "${clone_path}"
            git clone ${extra_args} "${repo_url}" "${clone_path}"
            git -C "${clone_path}" checkout "${ref}"
        }
    fi

    echo "  => Creating tar archive: ${tar_name}"
    tar -czf "${tar_path}" -C "${CLONE_DIR}" "${name}"

    local size
    size=$(du -h "${tar_path}" | cut -f1)
    echo "  => Done: ${tar_path} (${size})"
}

# ---------------------------------------------------------------------------
# REPOSITORY DEFINITIONS
# ---------------------------------------------------------------------------
# Format: "name|repo_url|ref|extra_git_args"

declare -a CUDA_REPOS=(
    # --- Core: vLLM (neuralmagic fork) ---
    "vllm|https://github.com/neuralmagic/vllm.git|51f799c1a0c8a0476faf7e17eeb6a77983cdd778|--depth=1"

    # --- RDMA / Communication ---
    "gdrcopy|https://github.com/NVIDIA/gdrcopy.git|v2.5.2|--depth=1"
    "ucx|https://github.com/openucx/ucx.git|v1.20.0|--depth=1"
    "uccl|https://github.com/uccl-project/uccl.git|v0.1.1|--depth=1"
    "nvshmem|https://github.com/NVIDIA/nvshmem.git|v3.4.5-0|--depth=1"
    "nixl|https://github.com/ai-dynamo/nixl.git|v1.2.0|--depth=1"

    # --- KV-Cache ---
    "infinistore|https://github.com/bytedance/InfiniStore.git|0.2.33|--depth=1"
    "lmcache|https://github.com/LMCache/LMCache.git|v0.4.6|--depth=1"

    # --- LLM Kernels ---
    "deepep|https://github.com/neuralmagic/DeepEP|38d21b7f9bb6f3b102b1819d09439686eaa87ce8|--depth=1"
    "deepep-gb200|https://github.com/tlrmchlsmth/DeepEP|sgl-gb200-blog-pt2|--depth=1"
    "deepgemm|https://github.com/deepseek-ai/DeepGEMM|477618cd51baffca09c4b0b87e97c03fe827ef03|--depth=1"
    "flashinfer|https://github.com/flashinfer-ai/flashinfer.git|v0.6.12|--depth=1"

    # --- llm-d components ---
    "llm-d|https://github.com/llm-d/llm-d.git|release-0.8|--depth=1"
    "llm-d-router|https://github.com/llm-d/llm-d-router.git|main|--depth=1"
    "llm-d-kv-cache|https://github.com/llm-d/llm-d-kv-cache.git|main|--depth=1"
    "llm-d-workload-variant-autoscaler|https://github.com/llm-d/llm-d-workload-variant-autoscaler.git|release-0.8|--depth=1"

    # --- GB200-specific DeepEP ---
    "deepep-gb200-fzyzcjy|https://github.com/fzyzcjy/DeepEP|gb200_blog_part_2|--depth=1"
)

declare -a ROCM_REPOS=(
    "rixl|https://github.com/ROCm/RIXL.git|39be1de|--depth=1"
    "ucx-rocm|https://github.com/ROCm/ucx.git|da3fac2a|--depth=1"
    "etcd-cpp-apiv3|https://github.com/etcd-cpp-apiv3/etcd-cpp-apiv3.git|7c6e714|--depth=1"
)

declare -a RDMA_TOOLS_REPOS=(
    "iperf|https://github.com/esnet/iperf.git|3.20|--depth=1"
    "tcpdump|https://github.com/the-tcpdump-group/tcpdump.git|tcpdump-4.99.6|--depth=1"
    "pciutils|https://github.com/pciutils/pciutils.git|v3.14.0|--depth=1"
    "perftest|https://github.com/linux-rdma/perftest.git|25.10.0-0.128|--depth=1"
    "nccl-tests|https://github.com/NVIDIA/nccl-tests.git|v2.17.8|--depth=1"
)

# ---------------------------------------------------------------------------
# Build final repo list based on flags
# ---------------------------------------------------------------------------
declare -a REPOS=()

if $CUDA_ONLY; then
    REPOS+=("${CUDA_REPOS[@]}")
elif $ROCM_ONLY; then
    REPOS+=("${ROCM_REPOS[@]}")
elif $CORE_ONLY; then
    REPOS+=("${CUDA_REPOS[@]}")
else
    REPOS+=("${CUDA_REPOS[@]}")
    REPOS+=("${ROCM_REPOS[@]}")
    if ! $CORE_ONLY; then
        REPOS+=("${RDMA_TOOLS_REPOS[@]}")
    fi
fi

# ---------------------------------------------------------------------------
# Show summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================================================================="
echo "  llm-d Repository Pull & Save"
echo "=============================================================================="
echo "  Repos to pull:   ${#REPOS[@]}"
echo "  Clone directory: ${CLONE_DIR}"
echo "  Output directory: ${OUTPUT_DIR}"
echo "  Flags: CUDA_ONLY=${CUDA_ONLY} ROCM_ONLY=${ROCM_ONLY} CORE_ONLY=${CORE_ONLY}"
echo "=============================================================================="

# ---------------------------------------------------------------------------
# Pull and tar each repo
# ---------------------------------------------------------------------------
MANIFEST="${OUTPUT_DIR}/MANIFEST.txt"
echo "# llm-d Repository Manifest - $(date '+%Y-%m-%d %H:%M:%S')" > "${MANIFEST}"
echo "# Format: name | repo_url | ref | tar_file" >> "${MANIFEST}"
echo "" >> "${MANIFEST}"

FAILED=()
for repo_def in "${REPOS[@]}"; do
    IFS='|' read -r name url ref extra_args <<< "${repo_def}"
    if clone_and_tar "${name}" "${url}" "${ref}" "${extra_args}"; then
        echo "${name} | ${url} | ${ref} | ${name}_${ref//\//_}.tar.gz" >> "${MANIFEST}"
    else
        echo "  *** FAILED: ${name} ***"
        FAILED+=("${name}")
    fi
done

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=============================================================================="
echo "  COMPLETE"
echo "=============================================================================="
echo "  Total repos:     ${#REPOS[@]}"
echo "  Successful:      $((${#REPOS[@]} - ${#FAILED[@]}))"
echo "  Failed:          ${#FAILED[@]}"
if [ ${#FAILED[@]} -gt 0 ]; then
    echo "  Failed repos:    ${FAILED[*]}"
fi
echo "  Tar files in:    ${OUTPUT_DIR}"
echo "  Manifest:        ${MANIFEST}"
echo ""
echo "  Total size:      $(du -sh "${OUTPUT_DIR}" | cut -f1)"
echo "=============================================================================="

exit ${#FAILED[@]}
