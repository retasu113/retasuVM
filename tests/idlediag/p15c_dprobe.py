#!/usr/bin/env python3
"""p15c_dprobe.py <dump> <VA> [len] -- qword dump of a VA region."""
import sys

sys.path.insert(0, '.')
from p5_common import Ctx  # noqa: E402


def main():
    ctx = Ctx(sys.argv[1])
    va = int(sys.argv[2], 0)
    n = int(sys.argv[3], 0) if len(sys.argv) > 3 else 0x100
    for off in range(0, n, 0x20):
        row = []
        for k in range(0, 0x20, 8):
            try:
                v = ctx.Qva(va + off + k)
            except Exception:
                v = None
            row.append('----------------' if v is None else f'{v:016x}')
        print(f'+0x{off:03x}: ' + ' '.join(row))


if __name__ == '__main__':
    main()
