import argparse
import re
import json
import time
import yaml

from dataclasses import dataclass
from typing import List


def main():
    args = parse_args()
    print(f"{args}")
    manifest["metadata"]["namespace"] = args.namespace
    manifest["metadata"]["name"] = get_pod_name(
        args.mode, args.group_id, args.instance_id, args.rank
    )
    manifest["spec"]["nodeSelector"] = args.node_labels
    manifest["spec"]["containers"][0]["image"] = args.image
    command = [
        "/bin/bash",
        f"{args.container_project_root_dir}/k8s/entrypoint.sh",
        f"{args.mode}",
        f"{args.group_id}",
        f"{args.instance_id}",
        f"{args.rank}",
        f"{args.timestamp_s}",
        f"{args.backend}",
        f"./{args.mode}.sh",
    ]
    if args.mode in ["prefill", "decode"]:
        command.extend([f"{args.master_ip}", f"{args.nnodes}", f"{args.rank}"])
    elif args.mode == "minilb":
        command.extend(["prefill"] + args.prefill + ["decode"] + args.decode)
    elif args.mode == "client":
        command.extend([f"{args.server_addr}"])
    else:
        raise ValueError(f"Unsupported mode: {args.mode}")
    manifest["spec"]["containers"][0]["command"] = command

    resources = {}
    if args.mode in ["prefill", "decode"]:
        resources = {
            "requests": {
                "memory": "500Gi",
                "cpu": 64,
                "metax-tech.com/gpu": 8,
            },
            "limits": {"memory": "500Gi", "cpu": 64, "metax-tech.com/gpu": 8},
        }
    else:
        resources = {
            "requests": {"memory": "16Gi", "cpu": "4"},
            "limits": {"memory": "16Gi", "cpu": "4"},
        }
    manifest["spec"]["containers"][0]["resources"] = resources

    mount_points: List[MountPoint] = args.mounts
    if args.mode in ["prefill", "decode"]:
        mount_points = args.mounts + [
            MountPoint("/opt/mxdriver:/opt/mxdriver:ro"),
            MountPoint("/dev/mxcd:/dev/mxcd"),
        ]
        mount_name = "share-memory"
        manifest["spec"]["volumes"].append(
            {
                "name": f"{mount_name}",
                "emptyDir": {"medium": "Memory", "sizeLimit": "32Gi"},
            }
        )
        manifest["spec"]["containers"][0]["volumeMounts"].append(
            {
                "name": f"{mount_name}",
                "mountPath": "/dev/shm",
            }
        )

    for mount_point in mount_points:
        mount_name = f"volume-{mount_point.mount_name}"
        manifest["spec"]["volumes"].append(
            {
                "name": f"{mount_name}",
                "hostPath": {"path": f"{mount_point.host}"},
            }
        )
        volume_mounts = {
            "name": f"{mount_name}",
            "mountPath": f"{mount_point.mount}",
        }
        if mount_point.readonly:
            volume_mounts["readOnly"] = True

        manifest["spec"]["containers"][0]["volumeMounts"].append(volume_mounts)

    print(yaml.safe_dump(manifest))


def get_pod_name(mode: str, group_id: int, instance_id: int, rank: int) -> str:
    res = f"group-{group_id}-{mode}"
    if mode in ["prefill", "decode"]:
        res += f"-{instance_id}-rank-{rank}"
    return res


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--backend",
        choices=["sglang", "vllm"],
        required=True,
        help="Backend type for the service",
    )
    parser.add_argument(
        "--mode",
        choices=["prefill", "decode", "minilb", "client"],
        required=True,
        help="Type of the service (prefill, decode, minilb)",
    )
    parser.add_argument(
        "--namespace", default="metax-ai-pd", help="Kubernetes namespace for the pods"
    )
    parser.add_argument(
        "--group-id", type=int, required=True, help="Group ID for the service"
    )
    parser.add_argument("--instance-id", type=int, help="Instance ID for the service")
    parser.add_argument(
        "--node-labels",
        type=KeyValue,
        nargs="+",
        action="extend",
        help="Node labels for scheduling the pod (e.g., 'pd-minilb=group-1')",
    )
    parser.add_argument(
        "--image", required=True, help="Container image to use for the pod"
    )
    parser.add_argument(
        "--mounts",
        type=MountPoint,
        nargs="*",
        action="extend",
        help="List of volume mounts in the format 'hostPath:mountPath' (e.g., '/bgfs:/mnt/dataset')",
    )
    parser.add_argument(
        "--container-project-root-dir",
        required=True,
        help="Root directory of the project inside the container",
    )
    parser.add_argument("--master-ip", help="Main IP address for the service")
    parser.add_argument(
        "--nnodes", type=int, help="Number of nodes in the cluster for synchronization"
    )
    parser.add_argument(
        "--rank", type=int, help="Rank of the current node for synchronization"
    )
    parser.add_argument(
        "--prefill",
        nargs="*",
        action="extend",
        help="List of prefill IPs for minilb mode",
    )
    parser.add_argument(
        "--decode",
        nargs="*",
        action="extend",
        help="List of decode IPs for minilb mode",
    )
    parser.add_argument("--server-addr", help="Server address for client mode")
    parser.add_argument(
        "--timestamp-s",
        type=int,
        required=True,
        help="timestamp in seconds",
    )
    args = parser.parse_args()

    args.node_labels = dict(args.node_labels)

    if args.mode in ["prefill", "decode"]:
        if args.master_ip is None:
            parser.error("--master-ip is required for prefill and decode modes")
            exit(1)
        if args.instance_id is None:
            parser.error("--instance-id is required for prefill and decode modes")
            exit(1)
        if args.nnodes is None:
            parser.error("--nnodes is required for prefill and decode modes")
            exit(1)
        if args.rank is None:
            parser.error("--rank is required for prefill and decode modes")
            exit(1)

    if args.mode == "minilb":
        if not args.prefill or not args.decode:
            parser.error("--prefill and --decode are required for minilb mode")
            exit(1)

    if args.mode == "client":
        if args.server_addr is None:
            parser.error("--server-addr is required for client mode")
            exit(1)
    return args


@dataclass
class KeyValue:
    key: str
    value: str

    def __init__(self, text: str):
        values = text.split("=", 1)
        if len(values) != 2:
            raise argparse.ArgumentTypeError(
                f"Invalid key-value format: '{text}'. Expected format is 'key=value'"
            )
        if any(not v for v in values):
            raise argparse.ArgumentTypeError(
                f"Invalid key-value format: '{text}'. Expected format is 'key=value'"
            )
        self.key = values[0]
        self.value = values[1]

    def __iter__(self):
        yield self.key
        yield self.value


_re_tr_alnum = re.compile(r"[^a-zA-Z0-9]+")


@dataclass
class MountPoint:
    host: str
    mount: str
    readonly: bool

    def __init__(self, text: str):
        values = text.split(":")
        if len(values) < 2 or len(values) > 3:
            raise argparse.ArgumentTypeError(
                f"Invalid mount point format: '{text}'. Expected format is 'hostPath:mountPath[:ro]'"
            )
        if any(not v for v in values):
            raise argparse.ArgumentTypeError(
                f"Invalid mount point format: '{text}'. Expected format is 'hostPath:mountPath[:ro]'"
            )
        host, mount = values[0], values[1]
        readonly = False
        if len(values) == 3:
            if values[2] != "ro":
                raise argparse.ArgumentTypeError(
                    f"Invalid mount point format: '{text}'. The third part can only be 'ro' to indicate read-only"
                )
            readonly = True
        self.host = host
        self.mount = mount
        self.readonly = readonly
        self.mount_name = _re_tr_alnum.sub("-", self.mount.strip("/ "))


manifest = {
    "apiVersion": "v1",
    "kind": "Pod",
    "metadata": {
        # "name": "group-1-minilb", # 名称空间内唯一的名称
        # "namespace": "metax-ai-pd"
    },
    "spec": {
        "hostNetwork": True,
        "hostUTS": True,
        "hostPID": True,
        "hostIPC": True,
        "nodeSelector": {
            # "pd-minilb": "group-1"
        },
        "tolerations": [
            {
                "key": "node-role.alibabacloud.com/bmcp",
                "operator": "Exists",
                "effect": "NoSchedule",
            },
            {
                "key": "node-role.kubernetes.io/control-plane",
                "effect": "NoSchedule",
                "operator": "Exists",
            },
            {
                "key": "node.kubernetes.io/disk-pressure",
                "effect": "NoSchedule",
                "operator": "Exists",
            },
        ],
        "containers": [
            {
                "name": "main",
                "securityContext": {
                    "privileged": True,
                    "runAsGroup": 44,  # video 组
                },
                # "image": "",
                "env": [],
                "command": [],
                "resources": {},
                "volumeMounts": [],
            }
        ],
        "volumes": [],
    },
}


if __name__ == "__main__":
    main()
