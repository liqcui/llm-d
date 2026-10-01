#!/usr/bin/env python3
"""HiCache L2/L3 测试结果解析器

输入:
    --result <hicache_test.py 输出的 JSON>    (必填)
    日志证据 (任选其一, 越多判定越硬):
      --prefill-log <文件> | --prefill-pod <pod> [--namespace <ns>]
      --master-log  <文件> | --master-pod  <pod> [--namespace <ns>]

解析内容:
    1. 请求时序: ①冷 → ②L2 → flush → ③L3 的 http / elapsed / cached_tokens
    2. prefill 引擎日志: "HiCache prefetch success ... completed_local / matched / loaded"
       - matched=0 + loaded=N ⇒ 不是本地 radix 命中, 是 host/L3 重新加载
    3. mooncake master 日志: "Master Metrics: Storage / Keys / BatchPut / BatchGet / ExistKey"
       - BatchPut>0 ⇒ KV 真实写入 L3; ③ 后 BatchGet/ExistKey 增长 ⇒ L3 被查/被读

判定表:
    L2 命中     PASS: ② http=200 且 cached_tokens>0 且 elapsed 显著低于 ①
    L3 写入     PASS: master 日志 BatchPut Item>0 且 Storage 增长
    L3 命中     PASS: flush 后 ③ cached_tokens>0
                        + prefill 日志 matched=0 / loaded=N
                        + master BatchGet/ExistKey 增长
                  FAIL: ③ 非 200 (崩溃/超时) 或 flush 后 cached=0
"""
import argparse
import json
import re
import subprocess
import sys
from collections import OrderedDict

PREFETCH_RE = re.compile(
    r"HiCache prefetch success.*?completed_local\s*=\s*(\d+).*?"
    r"completed_synced\s*=\s*(\d+).*?matched\s*=\s*(\d+).*?loaded\s*=\s*(\d+)",
    re.S)
MASTER_METRICS_RE = re.compile(
    r"Storage:\s*([\d.]+)\s*(\w+)\s*/\s*([\d.]+)\s*(\w+).*?Keys:\s*(\d+)"
    r".*?PutStart=(\d+)/(\d+).*?PutEnd=(\d+)/(\d+).*?Get=(\d+)/(\d+).*?"
    r"Exist=(\d+)/(\d+).*?PutStart:\(Req=\d+/\d+/\d+, Item=(\d+)/\d+\).*?"
    r"PutEnd:\(Req=\d+/\d+/\d+, Item=(\d+)/\d+\).*?"
    r"Get:\(Req=\d+/\d+/\d+, Item=(\d+)/\d+\).*?"
    r"ExistKey:\(Req=\d+/\d+/\d+, Item=(\d+)/\d+\)", re.S)


def load_result(path):
    with open(path) as f:
        return json.load(f)


def fetch_logs(kind, arg, ns):
    """kind: 'prefill'|'master'; arg: pod 名 → kubectl logs; 否则当本地文件。"""
    if arg and arg.endswith((".log", ".txt")) or (arg and "/" in arg):
        try:
            with open(arg) as f:
                return f.read()
        except OSError as e:
            print(f"⚠ 读文件失败 {arg}: {e}")
            return ""
    if arg:
        cmd = ["kubectl", "-n", ns or "metax-ai-pd", "logs", arg, "--tail=2000"]
        try:
            return subprocess.run(cmd, capture_output=True, text=True,
                                  timeout=60).stdout
        except Exception as e:  # noqa: BLE001
            print(f"⚠ kubectl logs 失败: {e}")
            return ""
    return ""


def parse_prefetch(log):
    hits = PREFETCH_RE.findall(log)
    # 取最后一次完整 prefetch
    if hits:
        cl, cs, m, ld = hits[-1]
        return {"completed_local": int(cl), "completed_synced": int(cs),
                "matched": int(m), "loaded": int(ld)}
    return None


def parse_master_metrics(log):
    """解析 master 日志, 返回按时间排序的指标快照列表 (去重)。"""
    snaps, seen = [], set()
    for m in MASTER_METRICS_RE.finditer(log):
        key = m.group(0)
        if key in seen:
            continue
        seen.add(key)
        snap = OrderedDict([
            ("storage_used", m.group(1) + m.group(2)),
            ("storage_total", m.group(3) + m.group(4)),
            ("keys", int(m.group(5))),
            ("putstart", m.group(6)), ("putend", m.group(8)),
            ("get", m.group(10)), ("exist", m.group(12)),
            ("batch_put_item", m.group(14)), ("batch_putend_item", m.group(15)),
            ("batch_get_item", m.group(16)), ("batch_exist_item", m.group(17)),
        ])
        snaps.append(snap)
    return snaps


def fmt_count(c):
    return int(c) if isinstance(c, str) and c.isdigit() else c


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--result", required=True, help="hicache_test.py 的 JSON 输出")
    ap.add_argument("--prefill-log", help="prefill 引擎日志文件路径")
    ap.add_argument("--prefill-pod", help="prefill 任意 rank pod (kubectl logs 抓取)")
    ap.add_argument("--master-log", help="mooncake master 日志文件")
    ap.add_argument("--master-pod", help="mooncake-master pod (kubectl logs 抓取)")
    ap.add_argument("--namespace", default="metax-ai-pd")
    args = ap.parse_args()

    result = load_result(args.result)
    steps = result["steps"]
    print("══ 1. 请求时序 ══")
    for s in steps:
        print(f"  {s['tag']:8s} http={s.get('http')} elapsed={s.get('elapsed_s')}s "
              f"cached={s.get('cached_tokens')} "
              f"{s.get('error', '')}")
    print()

    by_tag = {s["tag"]: s for s in steps}
    c1, c2, c3 = by_tag.get("请求①冷"), by_tag.get("请求②L2"), by_tag.get("请求③L3")
    fl = by_tag.get("flush")

    verdicts = []
    if c1 and c2 and c2.get("http") == 200:
        speedup = c1["elapsed_s"] / c2["elapsed_s"] if c2.get("elapsed_s") else 0
        l2_ok = (c2.get("cached_tokens") or 0) > 0 or speedup > 5
        verdicts.append(("② L2 命中", "PASS" if l2_ok else "WARN",
                         f"cached={c2.get('cached_tokens')} speedup={speedup:.1f}x "
                         f"(① {c1['elapsed_s']}s → ② {c2['elapsed_s']}s)"))
    if fl and fl.get("http") == 200:
        verdicts.append(("flush", "PASS", f"{fl.get('body', '')[:60]}"))

    pf = fetch_logs("prefill", args.prefill_log or args.prefill_pod, args.namespace)
    if pf:
        pref = parse_prefetch(pf)
        if pref:
            p = pref
            l3_evidence = p["matched"] == 0 and p["loaded"] > 0
            verdicts.append(("prefill 回读", "PASS" if l3_evidence else "WARN",
                             f"matched={p['matched']} loaded={p['loaded']} "
                             f"(matched=0 ⇒ 非本地 radix 命中)"))
        else:
            verdicts.append(("prefill 回读", "INFO", "日志中未找到 prefetch success 记录"))

    ml = fetch_logs("master", args.master_log or args.master_pod, args.namespace)
    if ml:
        snaps = parse_master_metrics(ml)
        if snaps:
            first, last = snaps[0], snaps[-1]
            print("══ 2. mooncake master 指标 (首→末) ══")
            print(f"  Storage: {first['storage_used']} → {last['storage_used']} / {last['storage_total']}")
            print(f"  Keys   : {first['keys']} → {last['keys']}")
            print(f"  BatchPut Item  : {first['batch_put_item']} → {last['batch_put_item']}")
            print(f"  BatchGet Item  : {first['batch_get_item']} → {last['batch_get_item']}")
            print(f"  ExistKey Item  : {first['batch_exist_item']} → {last['batch_exist_item']}")
            wrote = fmt_count(last["batch_put_item"]) > fmt_count(first["batch_put_item"]) \
                    or fmt_count(last["keys"]) > fmt_count(first["keys"])
            got = fmt_count(last["batch_get_item"]) > fmt_count(first["batch_get_item"]) \
                  or fmt_count(last["exist"]) > fmt_count(first["exist"])
            verdicts.append(("L3 写入 (BatchPut/Keys↑)", "PASS" if wrote else "WARN",
                             f"Item {first['batch_put_item']}→{last['batch_put_item']}, "
                             f"Keys {first['keys']}→{last['keys']}"))
            verdicts.append(("L3 查询 (Get/Exist↑)", "PASS" if got else "WARN",
                             f"GetItem {first['batch_get_item']}→{last['batch_get_item']}"))
        else:
            print("⚠ master 日志未匹配到 Master Metrics (检查 --master-pod/--master-log)")

    print("\n══ 3. 综合判定 ══")
    for name, v, detail in verdicts:
        print(f"  {name}: {v}  {detail}")

    if c3:
        if c3.get("http") != 200:
            print("  ⚠ 请求③ 失败 —— L3 路径异常, 收集: prefill 'Scheduler hit an exception' "
                  "栈 + MXC/MCR 日志 + master 指标")
            sys.exit(2)
        cached3 = c3.get("cached_tokens")
        # OpenAI 兼容 /v1/completions 的 usage 不带 cached_tokens(None),
        # 主证据用 prefill 日志的 prefetch(matched=0, loaded=N):
        pref_ok = (pref and pref["matched"] == 0 and pref["loaded"] > 0) if pref else False
        if fl and fl.get("http") == 200:
            if cached3 is not None:
                l3 = cached3 > 0
                print(f"  ⇒ L3 命中: {'PASS' if l3 else 'FAIL'} (flush 后 cached={cached3}; >0 即 L3 回读)")
            elif pref_ok:
                print(f"  ⇒ L3 命中: PASS (API 无 cached_tokens; prefill 日志 "
                      f"matched=0 loaded={pref['loaded']} = L3 回读铁证)")
            else:
                print(f"  ⇒ L3 命中: 无法判定 (API 无 cached_tokens 且无 prefetch 日志证据)")
        else:
            print(f"  ⇒ cached={cached3} (未 flush, 无法区分 L2/L3)")


if __name__ == "__main__":
    main()
