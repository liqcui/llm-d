import mooncake
print('mooncake:', mooncake.__file__)
from mooncake.store import MooncakeHostMemAllocator
print('MooncakeHostMemAllocator OK')
from mooncake.engine import TransferEngine
ms = [m for m in dir(TransferEngine()) if not m.startswith('_')]
print('TE is old MACA (PD-safe):', not ('scatter_transfer_sync_write_with_ticket' in ms))
print('TE API count:', len(ms))
