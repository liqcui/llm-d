#!/usr/bin/env python3
"""metax 补丁 (2026-09-27): standalone_storage (Dummy Client) 在 DSv4 混合池下误判。

问题
----
mooncake_store.py 的 standalone_storage 检查:
    if not isinstance(mem_pool.allocator, MooncakeHostTensorAllocator): raise
DSv4 混合池的 host_pool_group anchor 是 LogicalHostPool（"Pure-logical anchor
pool for V4 HiCache... holds no KV tensor"，allocator=None, kv_buffer=None），
实体 buffer 在 SWA/C4/C128 等子池（它们经 allocator_type=hicache_storage_backend
获得 MooncakeHostTensorAllocator）。同文件 register_mem_pool_host() 已明确支持
该形态（"Hybrid logical anchors only own allocation indices"），仅此检查遗漏。

改动
----
1. 新增 MooncakeStore._metax_host_buffers_use_mooncake_allocator():
   anchor 为 MooncakeHostTensorAllocator → 通过;
   否则检查 group 里所有携带实体 kv_buffer 的子池。
2. 原 isinstance 检查改为调用该方法 (错误信息不变)。
"""
import sys

PATH = (
    "/opt/conda/lib/python3.12/site-packages/sglang/srt/mem_cache/storage/"
    "mooncake_store/mooncake_store.py"
)

OLD_CHECK = """            if self.config.standalone_storage:
                if not isinstance(mem_pool.allocator, MooncakeHostTensorAllocator):
                    raise RuntimeError("""

NEW_CHECK = """            if self.config.standalone_storage:
                if not self._metax_host_buffers_use_mooncake_allocator(mem_pool):
                    raise RuntimeError("""

HELPER_ANCHOR = """    def __init__(
        self, storage_config: HiCacheStorageConfig = None, mem_pool: HostKVCache = None
    ):"""

HELPER = '''    @staticmethod
    def _metax_host_buffers_use_mooncake_allocator(mem_pool: Any) -> bool:
        """metax 补丁 (2026-09-27): DSv4 混合池的 anchor 是 LogicalHostPool
        (allocator=None, kv_buffer=None, 仅逻辑索引), 实体 buffer 在
        SWA/C4/C128 等子池 (经 allocator_type=hicache_storage_backend 获得
        MooncakeHostTensorAllocator)。此处改查实体子池; 与
        register_mem_pool_host() 对逻辑锚点的处理一致。"""
        alloc = getattr(mem_pool, "allocator", None)
        if isinstance(alloc, MooncakeHostTensorAllocator):
            return True
        entries = getattr(mem_pool, "entries", None)
        if entries:
            real_pools = [
                e.host_pool
                for e in entries
                if getattr(e.host_pool, "kv_buffer", None) is not None
            ]
            if not real_pools:
                return False
            return all(
                isinstance(getattr(p, "allocator", None), MooncakeHostTensorAllocator)
                for p in real_pools
            )
        return False

''' + HELPER_ANCHOR


def main():
    with open(PATH) as f:
        src = f.read()

    if "_metax_host_buffers_use_mooncake_allocator" in src:
        print("补丁已存在, 跳过")
        return

    n_check = src.count(OLD_CHECK)
    n_anchor = src.count(HELPER_ANCHOR)
    if n_check != 1 or n_anchor != 1:
        sys.exit(f"锚点不唯一: check={n_check}, anchor={n_anchor} (期望各 1)")

    src = src.replace(OLD_CHECK, NEW_CHECK)
    src = src.replace(HELPER_ANCHOR, HELPER)
    with open(PATH, "w") as f:
        f.write(src)
    print(f"补丁完成: {PATH}")


if __name__ == "__main__":
    main()
