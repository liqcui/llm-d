#!/usr/bin/env python3
"""统一镜像（unified）构建期全层核验 — 2026-10-15。

核验三层补丁全部在镜像内，缺任一即构建失败:
  L1 ModelSlim 0731 修复 : PATCH-0731 ×4 文件（modelslim / W8A8 linear / MoE×2）
  L2 llm-launch 适配      : /workspace/llm-launch 脚本版本/DSPARK/spec gate
  L3 retract 崩溃修复     : BH-retract-fix ×3 + BH-patch3 ×1
"""
import ast
import sys

FAIL = []


def check(path, needle, min_count=1, parse=False):
    try:
        src = open(path).read()
    except Exception as e:  # noqa: BLE001
        FAIL.append(f"MISSING {path}: {e}")
        return
    n = src.count(needle)
    if n < min_count:
        FAIL.append(f"MARKER {needle} x{n} < {min_count} in {path}")
    if parse:
        try:
            ast.parse(src)
        except SyntaxError as e:  # noqa: PERF203
            FAIL.append(f"SYNTAX {path}: {e}")


SRT = "/opt/conda/lib/python3.12/site-packages/sglang/srt/"

# ── L3 retract 崩溃修复 ──
check(SRT + "managers/schedule_batch.py", "[BH-retract-fix]", 3, parse=True)
check(SRT + "observability/func_timer.py", "[BH-patch3]", 1, parse=True)

# ── L1 ModelSlim 0731 修复 ──
for f in [
    "layers/quantization/modelslim/modelslim.py",
    "hardware_backend/npu/quantization/linear_method_npu.py",
    "hardware_backend/npu/quantization/fused_moe_method_npu.py",
    "layers/quantization/modelslim/schemes/modelslim_w8a8_int8_moe.py",
]:
    check(SRT + f, "PATCH-0731", 1, parse=True)

# ── L2 llm-launch 适配 ──
LL = "/workspace/llm-launch/sglang/"
check(LL + "common.sh", "v0.5.14")
check(LL + "decode.sh", "DSPARK")
check(LL + "models/deepseek-v4-flash-0731.sh", "PATCH-0731")

if FAIL:
    print("[verify-unified] FAILURES:")
    for m in FAIL:
        print("  -", m)
    sys.exit(1)
print("[verify-unified] ALL LAYERS OK: L1 modelslim(4) + L2 llm-launch(3) + L3 retract(3+1)")
