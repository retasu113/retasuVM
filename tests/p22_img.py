#!/usr/bin/env python3
"""Phase 22: parse the dyld cache imagesText array from decoded chunk 0
(/tmp/cache_dec_0.bin) and find the image containing unslid PC 0x1803089EC.
imagesTextOffset=0x19cc8, imagesTextCount=3257 (from the cache header)."""
import struct

CHUNK0 = "/tmp/cache_dec_1.bin"  # file offsets [0x10000, 0x20000)
CHUNK1 = "/tmp/cache_dec_2.bin"  # [0x20000, 0x30000)
CHUNK2 = "/tmp/cache_dec_3.bin"  # [0x30000, 0x40000)
PC = 0x1803089EC
BASE = 0x19cc8          # file offset of imagesText
COUNT = 3257

d = b"".join(open(p, "rb").read() for p in (CHUNK0, CHUNK1, CHUNK2))
BASE_OFF = BASE - 0x10000  # offset within the concatenated buffer
print(f"buffer len {len(d)} (file 0x10000..0x40000), imagesText at buf off {BASE_OFF:#x}")

# Try entry sizes; the array should be a monotonic run of loadAddress values
# in [0x180000000, 0x230000000).
for esz in (32, 40, 48, 56, 64):
    ok = 0
    prev = 0
    for i in range(min(COUNT, 200)):
        off = BASE_OFF + i * esz
        if off + 32 > len(d):
            break
        # candidate loadAddress at +16 (after 16-byte uuid)
        la = struct.unpack_from("<Q", d, off + 16)[0]
        if 0x180000000 <= la < 0x230000000 and la >= prev:
            ok += 1
            prev = la
        else:
            break
    print(f"entry size {esz}: monotonic loadAddress run = {ok}/200")

# dyld_cache_image_text_info is 32 B: uuid(16) + loadAddress(8)
# + textSegmentSize(u32) + pathOffset(u32).
esz = 32
entries = []
for i in range(COUNT):
    off = BASE_OFF + i * esz
    if off + 32 > len(d):
        break
    uuid = d[off:off + 16]
    la = struct.unpack_from("<Q", d, off + 16)[0]
    tsz, poff = struct.unpack_from("<II", d, off + 24)
    entries.append((la, tsz, poff, off, uuid))
# find containing image
for la, tsz, poff, off, uuid in entries:
    if la <= PC < la + tsz:
        print(f"\nPC in image: loadAddress={la:#x} textSegmentSize={tsz:#x} "
              f"range=[{la:#x},{la + tsz:#x}) entry_off={off:#x} pathOffset={poff:#x}")
        print(f"  uuid={uuid.hex()}")
        # path string: try pathOffset relative to imagesText start and to file start
        for base, name in ((BASE, "imagesText-relative"), (0, "file-relative")):
            po = base + poff
            if 0 <= po < 0x10000 + len(d):
                # map file offset into our buffer (buffer starts at file 0x10000)
                bo = po - 0x10000
                if 0 <= bo < len(d):
                    end = d.find(b"\x00", bo)
                    s = d[bo:end].decode("utf-8", "replace") if end > bo else ""
                    print(f"  path ({name}, file off {po:#x}): {s!r}")
        break
else:
    print("\nPC not inside any image range; nearest below:")
    below = [e for e in entries if e[0] <= PC]
    if below:
        la, tsz, poff, off, uuid = below[-1]
        print(f"  nearest loadAddress={la:#x} size={tsz:#x} end={la + tsz:#x} off={off:#x}")
    print(f"  total entries parsed: {len(entries)}")
