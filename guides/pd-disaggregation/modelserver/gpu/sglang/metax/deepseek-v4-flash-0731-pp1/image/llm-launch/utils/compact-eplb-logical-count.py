#!/usr/bin/env python3
import argparse
from pathlib import Path

import torch


def load_checkpoint(path: Path):
    try:
        return torch.load(path, map_location="cpu", weights_only=False)
    except TypeError:
        return torch.load(path, map_location="cpu")


def sum_logical_count(logical_count: torch.Tensor, chunk_size: int) -> torch.Tensor:
    if logical_count.ndim != 3:
        raise ValueError(f"expected logical_count to be 3D, got shape {tuple(logical_count.shape)}")
    if logical_count.dtype != torch.int32:
        raise ValueError(f"expected logical_count dtype torch.int32, got {logical_count.dtype}")

    total = torch.zeros(logical_count.shape[1:], dtype=torch.int64)
    for start in range(0, logical_count.shape[0], chunk_size):
        total += logical_count[start : start + chunk_size].to(torch.int64).sum(dim=0)
    return total


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Compact an EPLB expert_distribution_recorder checkpoint by summing "
            "logical_count over dim 0 and saving only logical_count."
        )
    )
    parser.add_argument("--input", type=Path, required=True, help="input .pt file")
    parser.add_argument("--output", type=Path, required=True, help="output .pt file")
    parser.add_argument(
        "--chunk-size",
        type=int,
        default=256,
        help="number of dim-0 slices to accumulate per step",
    )
    return parser.parse_args()


def main() -> None:
    args = parse_args()
    if args.chunk_size <= 0:
        raise ValueError("--chunk-size must be positive")

    checkpoint = load_checkpoint(args.input)
    if not isinstance(checkpoint, dict):
        raise TypeError(f"expected checkpoint dict, got {type(checkpoint).__name__}")
    if "logical_count" not in checkpoint:
        raise KeyError("checkpoint does not contain key 'logical_count'")

    logical_count = checkpoint["logical_count"]
    print(f"input logical_count dtype={logical_count.dtype} shape={tuple(logical_count.shape)}")

    summed = sum_logical_count(logical_count, args.chunk_size)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    torch.save({"logical_count": summed}, args.output)

    print(f"saved compact EPLB logical_count checkpoint {args.output}")
    print(f"logical_count dtype={summed.dtype} shape={tuple(summed.shape)}")


if __name__ == "__main__":
    main()
