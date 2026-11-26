import struct, sys
sys.path.insert(0, ".")
from p5_common import Ctx, census_threads, thread_info, make_sym

DUMP = "home_p30/dram_fpend_cycle1.bin"
ctx = Ctx(DUMP)
sym = make_sym()
print(f"kernel_task = {ctx.task_va:#x}  root = {ctx.root:#x}")

def cstr_at(va, off, n=48):
    raw = ctx.read_va(va + off, n)
    if raw is None: return None
    end = raw.find(b"\x00")
    try: return raw[:end if end>=0 else n].decode("ascii", "replace")
    except Exception: return None

def is_heap(v): return 0xFFFFFE0000000000 <= v <= 0xFFFFFEFFFFFFFFFF

# --- wqtrace proc ---
PROC = 0xFFFFFE2DDFFC63A0
print(f"\n== wqtrace proc {PROC:#x}: p_comm = {cstr_at(PROC, 0x5CC)!r}  p_name = {cstr_at(PROC, 0x5EC)!r}")
raw = ctx.read_va(PROC, 0x120)
for off in range(0, 0x120, 8):
    v = struct.unpack_from("<Q", raw, off)[0]
    tag = ""
    if v in (0,1,2,4,7,10,12): tag = " <-- small int (pid?)"
    if is_heap(v):
        c = cstr_at(v, 0x5CC, 20)
        if c and c.isprintable() and len(c) >= 3: tag = f" --> +0x5CC {c!r}"
    print(f"  proc+{off:#05x} = {v:#018x}{tag}")

# --- kernel_task bsd_info calibration ---
print("\n== kernel_task fields pointing at a struct with comm 'kernel_task' ==")
raw = ctx.read_va(ctx.task_va, 0x300)
for off in range(0, 0x300, 8):
    v = struct.unpack_from("<Q", raw, off)[0]
    if is_heap(v) and cstr_at(v, 0x5CC, 20) == "kernel_task":
        print(f"  task+{off:#x} -> {v:#x} (bsd_info candidate)")

# --- wqtrace thread ---
T = 0xFFFFFE2839D0B010
ti = thread_info(ctx, T)
print(f"\n== wqtrace thread {T:#x}: id={ti['id']:#x} name={ti['name']!r} state_byte={ti['state_byte']:#x} wait_event={ti['wait_event']:#x} ({sym(ti['wait_event']) if ti['wait_event'] else '-'})")
traw = ctx.read_va(T, 0x900)
u = lambda o: struct.unpack_from("<Q", traw, o)[0]
tro = u(0x3D8); proc2 = ctx.Qva(tro + 0x18) if tro else None
print(f"  t_tro={tro:#x} -> proc={proc2:#x} (wqtrace proc={PROC:#x}) comm={cstr_at(proc2, 0x5CC) if proc2 else None!r}")
print(f"  tasklist next(+0x3B8)={u(0x3B8):#x} prev(+0x3C0)={u(0x3C0):#x}")
for off, label in ((0xF8, "contextData"), (0x100, "upcb"), (0x108, "uNeon"), (0x148, "saved_ctx(p5)")):
    v = u(off)
    print(f"  thread+{off:#x} ({label}) = {v:#x}")
    if is_heap(v):
        sraw = ctx.read_va(v, 0x120)
        if sraw:
            for so in (0xF8, 0x100, 0x108):
                sv = struct.unpack_from("<Q", sraw, so)[0]
                print(f"      +{so:#x} = {sv:#018x}  sym={sym(sv) if is_heap(sv) else '-'}")
