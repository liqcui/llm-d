#!/usr/bin/env python3
"""render_site.py — 将部署目录 lws/ 下的 {{占位符}} 渲染为 site-config.env 中的真实值。

用法:
    cp <dir>/site-config.env.example <dir>/site-config.env   # 填真实 IP
    python3 tools/render_site.py <dir> [--check]
    kubectl apply -k <dir>/_rendered/lws/

--check: 只列出未解析占位符 (不写文件)。
"""
import os, re, sys

def load_env(path):
    cfg = {}
    for line in open(path, encoding="utf-8"):
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, v = line.split("=", 1)
        cfg[k.strip()] = v.strip()
    return cfg

def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    if len(args) != 1:
        print(__doc__); return 2
    target = os.path.abspath(args[0])
    cfg_path = os.path.join(target, "site-config.env")
    if not os.path.exists(cfg_path):
        print(f"[ERROR] 未找到 {cfg_path}（从 site-config.env.example 拷贝并填写）"); return 1
    cfg = load_env(cfg_path)
    src_root = os.path.join(target, "lws")
    out_root = os.path.join(target, "_rendered", "lws")
    pat = re.compile(r"\{\{([A-Z0-9_]+)\}\}")
    unresolved = set()
    n_files = n_sub = 0
    for dp, _, fns in os.walk(src_root):
        for fn in fns:
            sp = os.path.join(dp, fn)
            try: s = open(sp, encoding="utf-8").read()
            except UnicodeDecodeError: continue
            def sub(m):
                nonlocal n_sub
                k = m.group(1)
                if k in cfg and cfg[k] and not cfg[k].startswith("<"):
                    n_sub += 1
                    return cfg[k]
                unresolved.add(k)
                return m.group(0)
            t = pat.sub(sub, s)
            if check:
                continue
            op = os.path.join(out_root, os.path.relpath(sp, src_root))
            os.makedirs(os.path.dirname(op), exist_ok=True)
            open(op, "w", encoding="utf-8").write(t)
            n_files += 1
    if unresolved:
        print("[WARN] 未解析占位符:", ", ".join(sorted(unresolved)))
        if check: return 1
    if check:
        print("[check] 无未解析占位符" if not unresolved else "[check] 存在未解析占位符")
    else:
        print(f"[render] {n_files} 文件 -> {out_root}（{n_sub} 处替换）")
        print(f"[next]  kubectl apply -k {os.path.join(target, '_rendered', 'lws')}/")
    return 0

if __name__ == "__main__":
    sys.exit(main())
