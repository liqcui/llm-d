#!/usr/bin/env python3
"""HiCache L2 + Mooncake L3 测试工具 — DeepSeek-V4 长 prompt KV 复用链路

流程（对齐 GPUStack《Mooncake PD / Store 测试与验证报告》§8-13）:
    请求① 冷启动（无缓存, 全量 prefill 基线）
    请求② 相同 prompt → L2 命中 (Host DRAM → GPU)
    flush_cache (清 prefill 本地 L1/L2)
    请求③ 相同 prompt → L3 命中判据 (Mooncake Store → GPU)

判据:
    L2 命中: ② elapsed << ① 且 usage.cached_tokens > 0
    L3 命中: flush 后 ③ cached_tokens > 0（L2 已清, 命中的必是 L3）
             辅证: prefill 日志 "HiCache prefetch success ... matched=0 loaded=N"
                   + mooncake master "Batch Get / BatchPut" 计数 / Keys 非 0

用法（在 pd-bench-client 内执行, 该镜像带模型 tokenizer）:
    python3 hicache_test.py --router http://10.66.3.32:8001 \
        --prefill http://10.66.3.28:8000 \
        --model /workspace/data/DeepSeek-V4-Flash-FlexSMQ-AWQ-W8A8 \
        --prompt-tokens 1236 --json-out result.json
"""
import argparse
import json
import sys
import time

import requests

try:
    from transformers import AutoTokenizer
except ImportError:
    AutoTokenizer = None

SENTENCE = "The quick brown fox jumps over the lazy dog. "


def build_prompt(tokenizer, n_tokens):
    """用真实模型 tokenizer 构造恰好 ~n_tokens 的 prompt（重复句, 保证可复现）。"""
    ids = tokenizer(SENTENCE)["input_ids"]
    full = ids * (n_tokens // len(ids) + 2)
    return tokenizer.decode(full[:n_tokens], skip_special_tokens=True)


def call(args, tag, prompt, record):
    t0 = time.time()
    try:
        r = requests.post(
            args.router + "/v1/completions",
            json={
                "model": args.model,
                "prompt": prompt,
                "max_tokens": args.max_tokens,
                "temperature": 0,
                "ignore_eos": False,
            },
            timeout=args.timeout,
        )
        dt = time.time() - t0
        body = r.json()
        usage = body.get("usage", {})
        meta = body.get("meta_info", {})
        rec = {
            "tag": tag,
            "http": r.status_code,
            "elapsed_s": round(dt, 3),
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
            "cached_tokens": usage.get("cached_tokens", meta.get("cached_tokens")),
        }
        record.append(rec)
        line = (f"[{tag}] http={rec['http']} elapsed={rec['elapsed_s']}s "
                f"prompt={rec['prompt_tokens']} completion={rec['completion_tokens']} "
                f"cached={rec['cached_tokens']}")
        print(line)
        if r.status_code != 200:
            print(f"[{tag}] BODY: {json.dumps(body)[:600]}")
        return rec
    except Exception as e:  # noqa: BLE001
        rec = {"tag": tag, "http": 0, "elapsed_s": round(time.time() - t0, 3),
               "error": f"{type(e).__name__}: {e}"}
        record.append(rec)
        print(f"[{tag}] EXC: {rec['error']}")
        return rec


def flush_cache(args, record):
    t0 = time.time()
    try:
        r = requests.post(args.prefill + "/flush_cache?timeout=30", timeout=60)
        dt = round(time.time() - t0, 3)
        rec = {"tag": "flush", "http": r.status_code, "elapsed_s": dt,
               "body": r.text[:200]}
        record.append(rec)
        print(f"[flush] http={r.status_code} elapsed={dt}s body={r.text[:120]}")
        return rec
    except Exception as e:  # noqa: BLE001
        rec = {"tag": "flush", "http": 0, "elapsed_s": round(time.time() - t0, 3),
               "error": f"{type(e).__name__}: {e}"}
        record.append(rec)
        print(f"[flush] EXC: {rec['error']}")
        return rec


def judge(record):
    """按判据给出 PASS/WARN/FAIL 结论。"""
    verdicts = []
    by_tag = {r["tag"]: r for r in record}

    c1, c2, c3 = by_tag.get("请求①冷"), by_tag.get("请求②L2"), by_tag.get("请求③L3")
    fl = by_tag.get("flush")

    if c1:
        verdicts.append(("①冷基线", "PASS" if c1.get("http") == 200 else "FAIL",
                         f"elapsed={c1.get('elapsed_s')}s"))
    if c1 and c2 and c2.get("http") == 200:
        speedup = c1["elapsed_s"] / c2["elapsed_s"] if c2.get("elapsed_s") else 0
        cached = c2.get("cached_tokens")
        l2 = cached and cached > 0
        verdicts.append(("②L2命中", "PASS" if l2 else "WARN",
                         f"cached={cached} speedup={speedup:.1f}x"))
    if c3:
        if c3.get("http") == 200:
            cached = c3.get("cached_tokens")
            if fl and fl.get("http") == 200:
                verdict = "PASS" if cached and cached > 0 else "FAIL"
                verdicts.append(("③L3命中(flush后)", verdict,
                                 f"cached={cached} (L2已清, >0 即 L3)"))
            else:
                verdicts.append(("③cached(未flush)", "INFO",
                                 f"cached={cached} (本次未 flush, 无法区分 L2/L3)"))
        else:
            verdicts.append(("③L3命中", "FAIL/崩溃",
                             f"http={c3.get('http')} {c3.get('error', '')}"))
    return verdicts


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--router", required=True, help="PD router 地址, 如 http://10.66.3.32:8001")
    ap.add_argument("--prefill", required=True, help="prefill master 地址, 如 http://10.66.3.28:8000 (flush 用)")
    ap.add_argument("--model", required=True, help="模型路径 (bench pod 内 hostPath 路径)")
    ap.add_argument("--prompt-tokens", type=int, default=1236,
                    help="prompt 目标 token 数 (默认 1236; 大 L3 验证用 32000)")
    ap.add_argument("--max-tokens", type=int, default=32, help="生成 token 数")
    ap.add_argument("--rounds", type=int, default=1, help="每阶段重复轮数 (默认 1)")
    ap.add_argument("--skip-flush", action="store_true", help="跳过 flush 阶段 (只测 L2)")
    ap.add_argument("--timeout", type=int, default=300, help="单请求超时秒数 (冷 prefill 32K 需 >300)")
    ap.add_argument("--json-out", help="结果 JSON 输出路径 (供 analyze.py 解析)")
    args = ap.parse_args()

    if AutoTokenizer is None:
        sys.exit("需要 transformers (bench 镜像自带): pip install transformers")
    print(f"== 加载 tokenizer: {args.model}")
    tok = AutoTokenizer.from_pretrained(args.model)
    prompt = build_prompt(tok, args.prompt_tokens)
    ntok = len(tok(prompt)["input_ids"])
    print(f"== prompt 实际 token 数: {ntok}")
    sys.stdout.flush()

    record = {"args": vars(args), "prompt_tokens_actual": ntok, "steps": []}
    steps = record["steps"]

    for i in range(args.rounds):
        call(args, "请求①冷", prompt, steps)
        time.sleep(2)
        call(args, "请求②L2", prompt, steps)
        time.sleep(2)
        if not args.skip_flush:
            flush_cache(args, steps)
            time.sleep(3)
            call(args, "请求③L3", prompt, steps)
            time.sleep(2)

    record["verdicts"] = judge(steps)
    print("\n== 判定 ==")
    for name, v, detail in record["verdicts"]:
        print(f"  {name}: {v}  {detail}")

    if args.json_out:
        with open(args.json_out, "w") as f:
            json.dump(record, f, ensure_ascii=False, indent=2)
        print(f"\n== 结果已写: {args.json_out} (analyze.py 可深度解析)")


if __name__ == "__main__":
    main()
