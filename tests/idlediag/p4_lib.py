"""Phase-4 shared library: dump access, physmap anchors, page-table walk.

Ground truth (validated phases 1-3):
  DRAM base PA 0x70000000, dump file offset = PA - 0x70000000.
  KASLR slide 0x182B4000. Physmap OFF (VA-PA) = 0xFFFFFDFFAC000000
  (valid only for the static/physmap VA range, e.g. kernel image).
"""
import struct

DRAM_BASE = 0x70000000
DRAM_SIZE = 0x100000000  # 4 GiB
SLIDE = 0x182B4000
OFF = 0xFFFFFDFFAC000000


class Dump:
    def __init__(self, path):
        self.f = open(path, 'rb')

    def read_pa(self, pa, size):
        if pa < DRAM_BASE or pa + size > DRAM_BASE + DRAM_SIZE:
            raise ValueError(f'PA out of range: {pa:#x}+{size:#x}')
        self.f.seek(pa - DRAM_BASE)
        data = self.f.read(size)
        if len(data) != size:
            raise ValueError(f'short read at PA {pa:#x}')
        return data

    def u64_pa(self, pa):
        return struct.unpack('<Q', self.read_pa(pa, 8))[0]

    def u32_pa(self, pa):
        return struct.unpack('<I', self.read_pa(pa, 4))[0]

    # physmap (static VA range only)
    def phys_pa(self, va):
        return va - OFF

    def read_phys(self, va, size):
        return self.read_pa(self.phys_pa(va), size)

    def u64_phys(self, va):
        return self.u64_pa(self.phys_pa(va))


def walk(dump, root_pa, va, granule=14, root_level=0, trace=False):
    """Walk guest page tables. granule: log2 page size (14 = 16K).
    root_level: level of the table root_pa points to (0 => index bits
    [47:47] for 16K/48-bit VA). Returns PA or None.
    Descriptor formats (ARMv8): table desc bits[1:0]=0b11 (levels<last),
    block desc bits[1:0]=0b01, page desc (last level) bits[1:0]=0b11.
    """
    page_size = 1 << granule
    idx_bits = granule - 3  # 11 for 16K
    # levels from root_level..3 ; shift for level L index:
    # L3 (last): page offset bits = granule
    # index shift for level L = granule + (3-L)*idx_bits
    table_pa = root_pa
    for level in range(root_level, 4):
        shift = granule + (3 - level) * idx_bits
        idx = (va >> shift) & ((1 << idx_bits) - 1)
        if level == root_level and root_level == 0:
            # L0 for 48-bit VA / 16K granule has only 2 entries (bit 47)
            idx = (va >> 47) & 0x1
            shift = 47
        # NOTE: root L1 index is VA bits [46:36] (11 bits) -- proven by
        # the table-side enumeration (p4_step2): physmap segments
        # reconstruct exactly with VA = PA + OFF under this geometry,
        # and the msgbuf page reverse-maps to VA 0xFFFFFE0022A22484
        # (l1=0x7E0 l2=0x11 l3=0x288).
        entry = dump.u64_pa(table_pa + idx * 8)
        if trace:
            print(f'  L{level} table={table_pa:#x} idx={idx} entry={entry:#018x}')
        if entry & 0x1 == 0:
            return None
        typ = entry & 0x3
        if level == 3:
            if typ != 0x3:
                return None
            base = entry & 0x0000FFFFFFFFC000
            return base + (va & (page_size - 1))
        if typ == 0x3:  # table descriptor
            table_pa = entry & 0x0000FFFFFFFFC000
            continue
        if typ == 0x1:  # block descriptor
            oa_mask = (~0) & ~((1 << shift) - 1) & 0x0000FFFFFFFFFFFF
            base = entry & oa_mask
            return base + (va & ((1 << shift) - 1))
        return None
    return None


def try_configs(dump, root_pa, anchors):
    """anchors: list of (va, expected_pa_or_None, name). Try walk configs
    and report which validates all anchors with known PA."""
    configs = []
    for granule in (14, 12):
        for root_level in (0, 1):
            configs.append((granule, root_level))
    results = {}
    for granule, root_level in configs:
        ok = True
        detail = []
        for va, exp, name in anchors:
            got = walk(dump, root_pa, va, granule, root_level)
            good = (got == exp) if exp is not None else (got is not None)
            detail.append((name, got, exp, good))
            if exp is not None and got != exp:
                ok = False
        results[(granule, root_level)] = (ok, detail)
    return results
