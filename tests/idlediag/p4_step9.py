"""Phase 4 step 9: find where thread names are stored.

Search the whole dump for the exact name strings; classify hits by
whether they fall inside the msgbuf ring (PA 0x76A20000..0x76A40000).
Non-msgbuf hits = stored thread names (uthread uu_name / tro).
"""
import sys

DUMP = '/home/retasu/retasuvm/inst/imagetest/home_idlediag/dram_idlediag1.bin'
DRAM = 0x70000000
MSGBUF_LO, MSGBUF_HI = 0x76A20000, 0x76A40000

data = open(DUMP, 'rb').read()
for name in [b"IOConfigThread_'Container'", b"IOConfigThread_'AppleAPFSMedia'",
             b"IOConfigThread_'IOResources'"]:
    hits = []
    i = data.find(name)
    while i != -1:
        hits.append(i)
        i = data.find(name, i + 1)
    outside = [h for h in hits
               if not (MSGBUF_LO - DRAM <= h < MSGBUF_HI - DRAM)]
    print(f'{name}: {len(hits)} hits, {len(outside)} outside msgbuf')
    for h in outside[:6]:
        pa = h + DRAM
        ctx = data[h - 0x40:h + 0x60]
        print(f'   PA {pa:#x} ctx={ctx!r}')
