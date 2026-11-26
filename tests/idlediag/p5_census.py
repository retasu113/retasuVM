"""Phase 5 census: validate walk, census all threads, roster with
wait_event grouping. Usage: python3 p5_census.py <dump> [out.json]"""
import collections
import json
import sys

sys.path.insert(0, '.')
from p5_common import Ctx, census_threads, thread_info  # noqa: E402

dump = sys.argv[1]
ctx = Ctx(dump)
print(f'TTBR root PA = {ctx.root:#x}  kernel_task VA = {ctx.task_va:#x}  '
      f'segments = {len(ctx.segs)}')

threads = census_threads(ctx)
print(f'{len(threads)} validated thread structs')

infos = {}
for tva in threads:
    ti = thread_info(ctx, tva)
    if ti:
        infos[tva] = ti

by_wait = collections.Counter(ti['wait_event'] for ti in infos.values())
print('\n--- wait_event census (count, event) ---')
for ev, n in by_wait.most_common():
    print(f'  {n:3d} x {ev:#018x}')

print('\n--- roster ---')
for tva, ti in sorted(infos.items(), key=lambda kv: (kv[1]['id'] or 0)):
    print(f"  id={ti['id']:#06x} state=0x{ti['state_byte']:02x} "
          f"wait={ti['wait_event']:#018x} thread={tva:#x} "
          f"name={ti['name']!r}")

if len(sys.argv) > 2:
    out = {f'{tva:#x}': {k: v for k, v in ti.items() if k != 'raw'}
           for tva, ti in infos.items()}
    json.dump(out, open(sys.argv[2], 'w'), indent=1)
    print(f'\nwrote {sys.argv[2]}')
