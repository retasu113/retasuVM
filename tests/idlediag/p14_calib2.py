"""Phase 14 calibration step 2: dump every u32/qword of the root
mount struct (found via apfs_vfsops) to pin the true offsets of
mnt_flag and the vfsstatfs block.

Usage: python3 p14_calib2.py <dump> <mount_base_va_hex>
"""
import struct
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402


def main():
    ctx = Ctx(sys.argv[1])
    base = int(sys.argv[2], 16)
    raw = ctx.read_va(base, 0x920)
    assert raw is not None
    print(f'mount base {base:#x}')
    print('--- u32 view +0x00..+0x100 ---')
    for off in range(0, 0x100, 4):
        v = struct.unpack_from('<I', raw, off)[0]
        print(f'  +{off:#05x} u32 {v:#010x}')
    print('--- strings in +0x00..+0x920 ---')
    off = 0
    while off < len(raw):
        b = raw[off]
        if 32 <= b < 127:
            end = raw.find(b'\x00', off)
            if end - off >= 2:
                print(f'  str +{off:#05x}: {raw[off:end].decode()!r}')
                off = end + 1
                continue
        off += 1
    print('--- qwords +0x00..+0x60 (list/op area) ---')
    for off in range(0, 0x60, 8):
        print(f'  +{off:#05x} {struct.unpack_from("<Q", raw, off)[0]:#018x}')


if __name__ == '__main__':
    main()
