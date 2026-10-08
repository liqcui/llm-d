#!/bin/bash
# 功能: 在本地主机上启动一个容器并运行指定命令
# Usage: ./launch-on-host.sh <command to run...>
# 可配置的环境变量参数:
#   MY_CONTAINER_IMAGE_FILE: 本地镜像文件路径, 如果指定则从该文件加载镜像
#   MY_CONTAINER_IMAGE_REMOTE: 远程镜像地址, 如果指定则从该地址拉取镜像
#   MY_CONTAINER_IMAGE_NAME: 镜像名称
#   MY_CONTAINER_NAME: 容器名称
#   MY_CONTAINER_REUSE: 是否复用已有容器, 0 表示不复用, 1 表示复用, 默认为 0

set -euE
shopt -s inherit_errexit

script_dir="$(cd "$(dirname "$0")" && pwd)"
readonly script_dir

source "$script_dir/error.sh"

[ "$#" -eq 0 ] && {
    echo "Usage: $0 <command to run...>" >&2
    exit 1
}

readonly image="${MY_CONTAINER_IMAGE:-}"
readonly image_name="${MY_CONTAINER_IMAGE_NAME:-}"
readonly container_name="${MY_CONTAINER_NAME:-llm-default-container}"
readonly flag_check_container_match=${MY_CONTAINER_CHECK_CONTAINER_MATCH:-1}
container_engine="${MY_CONTAINER_ENGINE:-}"
[ -z "$container_engine" ] && {
    candidates=()
    command -v nerdctl >/dev/null && candidates+=("nerdctl")
    command -v podman >/dev/null && candidates+=("podman")
    command -v docker >/dev/null && candidates+=("docker")
    [ "${#candidates[@]}" -gt 0 ] || log_fatal "Container engine is not specified and neither docker nor nerdctl command found. Please set MY_CONTAINER_ENGINE environment variable to either 'docker' or 'nerdctl', or install one of them and ensure it's in the PATH."
    [ "${#candidates[@]}" -eq 1 ] || log_fatal "Multiple container engines found (${candidates[*]}). Please set MY_CONTAINER_ENGINE environment variable to specify which one to use."
    container_engine="${candidates[0]}"
}
readonly container_engine

image_id="$(echo "$image_name" | perl -nle 'print $1 if /^(?:sha\d+:)?([0-9a-f]{64})$/')"
image_repository=""
image_tag=""
[ -z "$image_id" ] && {
    image_repository="${image_name%%:*}"
    image_tag="${image_name#*:}"
}
readonly image_id image_repository image_tag

echo "Image: $image, $image_name"

mount_dir() {
    local -r source="$1"
    local -r target="$2"
    mountpoint -q "$target" && return 0
    [ -d "$target" ] || sudo mkdir -p "$target"
    (set -x; sudo mount "$source" "$target")
}

image_exists() {
    "$container_engine" image inspect "$image_name" &>/dev/null
}

image_load() {
    local local_image=0
    local remote_image=0
    if [[ "$image" = "/"* ]] || [[ "$image" = *".tar" ]] || [ -f "$image" ]; then
        local_image=1
    else
        remote_image=1
    fi
    if [[ "$local_image" -ne 0 ]]; then
        echo "Loading image from file $image ..."
        #sudo 
        cat "$image" | "$container_engine" load || log_fatal "Failed to load image from $image"
    elif [[ "$remote_image" -ne 0 ]]; then
        echo "Pulling image from $image ..."
        "$container_engine" pull "$image" || log_fatal "Failed to pull image from $image"
    else
        log_fatal "No valid image source specified. Please set MY_CONTAINER_IMAGE to a valid local image file path or a remote image name."
    fi
    true
}

check_container_match() {
    local l_image_name l_image_id
    if [[ "|docker|podman|" = *"|$container_engine|"* ]]; then
        l_image_name="$("$container_engine" inspect --format '{{.Config.Image}}' "$container_name")"
    elif [ "$container_engine" = "nerdctl" ]; then
        l_image_name="$(nerdctl inspect --format '{{.Image}}' "$container_name")"
    else
        log_fatal "Unsupported container engine: $container_engine"
    fi
    l_image_id="$("$container_engine" image inspect --format '{{.Id}}' "$l_image_name")"
    [ -n "$image_id" ] && [ "$l_image_id" == "$image_id" ] && return 0
    [ -n "$image_repository" ] && [[ "$l_image_name" = *"$image_repository:$image_tag" ]] && return 0
    echo "Container $container_name is using image $l_image_name (id: $l_image_id), which does not match expected image $image_name." >&2
    return 1
}

container_exists() {
    "$container_engine" inspect "$container_name" &>/dev/null || return 1
    if [ "$flag_check_container_match" -ne 0 ] && ! check_container_match ; then
        container_stop
        container_wait
        container_remove
        return 1
    fi
    true
}

container_volume() {
        local -n var_ref="$1"
        local -r target="$2"
        local -r type="$3"
        local -r readonly="${4:-}"
        local volume="" readonly_flag=""
        if [ "$type" = "file" ]; then
            [ -f "$target" ] && volume=1
        elif [ "$type" = "dir" ]; then
            [ -d "$target" ] && volume=1
        else
            [ -e "$target" ] && volume=1
        fi
        [[ "$volume" -ne 0 ]] && {
            # shellcheck disable=SC2015
            [ -n "$readonly" ] && readonly_flag=":ro"
            var_ref+=(--volume="$target:$target$readonly_flag")
        }
        true
}

container_create() {
    image_exists || image_load
    args=(
        --privileged
        --group-add=video
        --network=host
        --ipc=host
        --uts=host
        --pid=host
        # --memory=512G
        --ulimit=memlock=-1
    )

    container_volume args "/opt/htdriver" dir ro
    container_volume args "/opt/mxdriver" dir ro
    container_volume args "/bgfs" dir

    # 8 pcie
    container_volume args "/opt/pci_switch_link" dir
    container_volume args "/etc/metax.conf" file
    container_volume args "/metax0402" dir
    args+=(
        --name="$container_name"
        "$image_name"
    )

    (set -x; "$container_engine" create -t "${args[@]}" /bin/bash >/dev/null)

}

container_running() {
    local l_running
    l_running="$("$container_engine" inspect -f '{{.State.Running}}' "$container_name")"
    [ "$l_running" = "true" ]
}

container_start() {
    echo "Starting container $container_name ..."
    "$container_engine" start "$container_name" >/dev/null
}

container_stop() {
    echo "Stopping container $container_name ..."
    "$container_engine" stop -t 5 "$container_name" >/dev/null || "$container_engine" kill "$container_name" || true
}

container_wait() {
    echo "Waiting for container $container_name to stop ..."
    "$container_engine" wait "$container_name" >/dev/null || true
}

container_remove() {
    "$container_engine" rm "$container_name" >/dev/null || true
}

kill_all_process() {
    echo "Killing all GPU processes..."
    if command -v ht-smi >/dev/null; then
        ht-smi --kill-all-process
    elif command -v mx-smi >/dev/null; then
        mx-smi --kill-all-process
    elif command -v nvidia-smi >/dev/null; then
        nvidia-smi --query-compute-apps=pid --format=csv,noheader | sudo xargs -r kill -9
    else
        log_fatal "No supported GPU monitoring tool found to kill processes. Please install ht-smi, mx-smi or nvidia-smi."
    fi
    true
}

# mount_dir "source" "target"

if [[ "${MY_CONTAINER_REUSE:-0}" -eq 0 ]]; then
    container_exists && {
        container_stop
        container_wait
        container_remove
    }
    container_create
else
    container_exists || container_create
fi

container_running || container_start

(set -x; "$container_engine" exec -it "$container_name" "$@") || log_fatal "Failed to execute command($*, exit: $?) in container."
