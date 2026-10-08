#!/opt/conda/bin/python3
# ═══════════════════════════════════════════════════════════════════════════
# [BH-retract-fix] 0.5.14-maca 官方镜像最小补丁 — decode retract 崩溃修复
#
# 问题（2026-10-08 实测，2 次全组崩溃复现，traceback 完整）:
#   decode 组高并发下触发 KV 压力 retract:
#     schedule_batch.py:2544 retract_decode -> release_req (:1619, 无条件)
#       -> Req.offload_kv_cache (:1507) -> swa.py:382 get_cpu_copy
#       -> memory_pool.py:1221 raise NotImplementedError()   ← 混合 SWA 池未实现
#   → scheduler 进程崩 → gloo MLP-sync all_gather 级联（所有 rank "Connection
#     closed by peer"）→ 每 pod http-server 重入触发 DuplicateTimeseries → 整组退出
#   （与 2026-10-02 0.5.12 同款双缺陷；本次 0.5.14 复现同链）
#
# 修复（对齐 0.5.12 patch 0001+0002 的修法，仅 3 处）:
#   A. retract_decode 主循环: 当 disaggregation_decode_enable_offload_kvcache=False
#      （无 CPU offload 能力）→ 不 retract, 改 FINISH_ABORT 优雅降级（客户端 500, 服务不崩）
#      （与 0.5.14 已有的 "last request OOM abort" 块同款模式）
#   B. release_req: offload_kv_cache 调用加 offload 能力 gate（防御纵深）
#   C. func_timer.py: Histogram 重复注册 guard（防 DuplicateTimeseries 把
#      "单 scheduler 死亡" 放大成 "整 pod 进程退出"）
# ═══════════════════════════════════════════════════════════════════════════
import ast
import sys

BASE = "/opt/conda/lib/python3.12/site-packages/sglang/srt/"

EDITS = {
    BASE + "managers/schedule_batch.py": [
        # ── A1. 提前初始化 reqs_to_abort（循环内降级 append 用）──
        (
            """        retracted_reqs = []
        first_iter = True""",
            """        retracted_reqs = []
        reqs_to_abort: List[Req] = []  # [BH-retract-fix] 提前初始化
        first_iter = True""",
        ),
        # ── A2. 主循环: 无 offload 能力 -> abort 降级 + 删除原位的重复初始化 ──
        (
            """            first_iter = False
            idx = sorted_indices.pop()
            req = self.reqs[idx]
            retracted_reqs.append(req)
            # release memory and don't insert into the tree because we need the space instantly
            self.release_req(idx, len(sorted_indices), server_args)

        reqs_to_abort: List[Req] = []
        if len(sorted_indices) <= 1 and not self.check_decode_mem(""",
            """            first_iter = False
            idx = sorted_indices.pop()
            req = self.reqs[idx]
            if not server_args.disaggregation_decode_enable_offload_kvcache:
                # [BH-retract-fix] 混合 SWA 池无 get_cpu_copy; 无 offload 能力时
                # retract 后 resume 必崩 (AttributeError: kv_cache_cpu) -> 优雅降级为 abort
                req.to_finish = FINISH_ABORT(
                    "Retracted due to KV cache pressure without CPU offload support; aborting.",
                    status_code=HTTPStatus.INTERNAL_SERVER_ERROR,
                )
                reqs_to_abort.append(req)
                self.release_req(idx, len(sorted_indices), server_args)
            else:
                retracted_reqs.append(req)
                # release memory and don't insert into the tree because we need the space instantly
                self.release_req(idx, len(sorted_indices), server_args)

        if len(sorted_indices) <= 1 and not self.check_decode_mem(""",
        ),
        # ── B. release_req: offload 调用加能力 gate ──
        (
            """    if server_args.disaggregation_mode == "decode":
        req.offload_kv_cache(req_to_token_pool, token_to_kv_pool_allocator)""",
            """    if (
        server_args.disaggregation_mode == "decode"
        and server_args.disaggregation_decode_enable_offload_kvcache
    ):
        # [BH-retract-fix] 无 offload 能力时不得调用 (混合 SWA 池 get_cpu_copy 未实现)
        req.offload_kv_cache(req_to_token_pool, token_to_kv_pool_allocator)""",
        ),
    ],
    BASE + "observability/func_timer.py": [
        # ── C. DuplicateTimeseries guard（对齐 0.5.12 patch 0002）──
        (
            """    FUNC_LATENCY = Histogram(
        "sglang:func_latency_seconds",
        "Function latency in seconds",
        # captures latency in range [50ms - ~50s]
        buckets=exponential_buckets(start=0.05, width=1.5, length=18),
        labelnames=["name"],
    )""",
            """    try:
        FUNC_LATENCY = Histogram(
            "sglang:func_latency_seconds",
            "Function latency in seconds",
            # captures latency in range [50ms - ~50s]
            buckets=exponential_buckets(start=0.05, width=1.5, length=18),
            labelnames=["name"],
        )
    except ValueError:
        # [BH-patch3] 防 DuplicateTimeseries: lifespan 重入/重启时复用已注册的 collector
        from prometheus_client import REGISTRY
        FUNC_LATENCY = REGISTRY._names_to_collectors.get("sglang:func_latency_seconds")""",
        ),
    ],
}


def main() -> int:
    for path, edits in EDITS.items():
        src = open(path).read()
        if "[BH-retract-fix]" in src or "[BH-patch3]" in src:
            print(f"[skip] {path}: 已有补丁标记（幂等）")
            continue
        for i, (old, new) in enumerate(edits, 1):
            n = src.count(old)
            if n != 1:
                print(f"[FATAL] {path} edit#{i}: 目标片段出现 {n} 次 (期望 1)", file=sys.stderr)
                return 1
            src = src.replace(old, new)
            print(f"[ok] {path} edit#{i} applied")
        try:
            ast.parse(src)
        except SyntaxError as e:
            print(f"[FATAL] {path} 语法错误: {e}", file=sys.stderr)
            return 1
        open(path, "w").write(src)
        print(f"[done] {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
