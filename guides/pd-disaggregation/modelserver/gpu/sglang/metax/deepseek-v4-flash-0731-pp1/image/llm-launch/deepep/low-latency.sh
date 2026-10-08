#!/bin/bash

set -euE
shopt -s inherit_errexit
trap 'echo "[ERROR] Script failed at line $LINENO. Command: [$BASH_COMMAND] (Exit status: $?)" >&2' ERR

script_dir="$(cd "$(dirname "$0")" && pwd)"
project_dir="$(dirname "$script_dir")"
readonly script_dir project_dir
cd "$script_dir"

[ "$#" -eq 3 ] || {
    echo "Usage: $0 <master node ip> <nnodes> <node rank>" >&2
    exit 1
}

readonly master_node_ip="$1"
readonly nnodes="$2"
readonly node_rank="$3"

# shellcheck source=../utils/utils.sh
source "$project_dir/utils/utils.sh"

init_conda_python
set_env_filter

readonly hca_list="mlx5_bond_2,mlx5_bond_3,mlx5_bond_4,mlx5_bond_5"
net_primary_iface="$(get_net_primary_iface)"
readonly net_primary_iface

readonly maca_dir=/opt/maca
mxshmem_dir="$(get_mxshmem_dir)"
readonly mxshmem_dir
path_prepend LD_LIBRARY_PATH "$mxshmem_dir/lib" "$maca_dir/mxgdrcopy/lib" "$maca_dir/lib" "$maca_dir/ompi/lib" "$maca_dir/mxgpu_llvm/lib" "/usr/local/lib"

export MACA_PATH="$maca_dir"
export MXSHMEM_PATH="$mxshmem_dir"
export MXSHMEM_BOOTSTRAP_UID_SOCK_IFNAME="$net_primary_iface"
export NVSHMEM_BOOTSTRAP_UID_SOCK_IFNAME="$net_primary_iface"
export MCCL_SOCKET_IFNAME="$net_primary_iface"
export NCCL_SOCKET_IFNAME="$net_primary_iface"
export GLOO_SOCKET_IFNAME="$net_primary_iface"

export MXSHMEM_DISABLE_CUDA_VMM=1
export NVSHMEM_DISABLE_CUDA_VMM="$MXSHMEM_DISABLE_CUDA_VMM"

export MCCL_IB_HCA="$hca_list"
export NCCL_IB_HCA="$hca_list"
export MXSHMEM_HCA_LIST="$hca_list"
export NVSHMEM_HCA_LIST="$hca_list"

export MXSHMEM_SYMMETRIC_SIZE=3g
export NVSHMEM_SYMMETRIC_SIZE="$MXSHMEM_SYMMETRIC_SIZE"

# export NVSHMEM_IB_ENABLE_IBGDA=1
# export MXSHMEM_IB_ENABLE_IBGDA=1

export MASTER_ADDR="$master_node_ip"
export MASTER_PORT=39543
export WORLD_SIZE="$nnodes"
export RANK="$node_rank"

show_filtered_env
cd "$script_dir/src"
if [ "$WORLD_SIZE" -eq 1 ]; then
    time python3 "low_latency.py"
else
    time python3 "internode.py"
fi
