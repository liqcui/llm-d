"""校验混合镜像: engine.so 已换回旧 MACA TE (PD 可用), 新 store 保留 (dummy client)。"""
from mooncake.engine import TransferEngine

ms = [m for m in dir(TransferEngine()) if not m.startswith('_')]
ok_old = not ('scatter_transfer_sync_write_with_ticket' in ms)
print('TE is old MACA (PD-safe):', ok_old)
assert ok_old, 'engine.so 替换失败 (仍是新 TE)'

from mooncake.store import MooncakeHostMemAllocator  # noqa: F401
print('new store (MooncakeHostMemAllocator) OK')
