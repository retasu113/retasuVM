import Foundation

// Unit differential for VirtioDevice.virtqPop head selection.
// Builds a spec-layout avail ring in fake guest RAM and checks that
// pop returns the head stored in avail entry[lastAvail] (the virtio
// spec / Henge hv_virtq_pop behaviour), not some other ring field.
//
// Avail ring layout (bytes): flags u16 @0, idx u16 @2, entries u16 @4+2*k.
// Desc ring: 16-byte descriptors. Used ring: flags @0, idx @2, entries @4+8*k.

var ram = [UInt8](repeating: 0, count: 1 << 20)

func w16(_ pa: Int, _ v: UInt16) { ram[pa] = UInt8(v & 0xFF); ram[pa + 1] = UInt8(v >> 8) }
func w32(_ pa: Int, _ v: UInt32) { for i in 0..<4 { ram[pa + i] = UInt8((v >> UInt32(8 * i)) & 0xFF) } }
func w64(_ pa: Int, _ v: UInt64) { for i in 0..<8 { ram[pa + i] = UInt8((v >> UInt64(8 * i)) & 0xFF) } }
func r16(_ pa: Int) -> UInt16 { UInt16(ram[pa]) | UInt16(ram[pa + 1]) << 8 }
func r32(_ pa: Int) -> UInt32 { (0..<4).reduce(UInt32(0)) { $0 | UInt32(ram[pa + $1]) << UInt32(8 * $1) } }

func desc(_ ring: Int, _ i: Int, _ addr: UInt64, _ len: UInt32, _ flags: UInt16, _ next: UInt16) {
    let p = ring + 16 * i
    w64(p, addr); w32(p + 8, len); w16(p + 12, flags); w16(p + 14, next)
}

let DESC = 0x1000, AVAIL = 0x2000, USED = 0x3000

let dev = VirtioDevice(deviceId: 2, classCode: 0x010000, nq: 1, features: 0)
dev.physRead = { pa, n in
    let a = Int(pa)
    guard a >= 0 && a + n <= ram.count else { return nil }
    return [UInt8](ram[a..<(a + n)])
}
dev.physWrite = { pa, bytes in
    let a = Int(pa)
    guard a >= 0 && a + bytes.count <= ram.count else { return }
    ram.replaceSubrange(a..<(a + bytes.count), with: bytes)
}
dev.queues[0].size = 16
dev.queues[0].desc = UInt64(DESC)
dev.queues[0].avail = UInt64(AVAIL)
dev.queues[0].used = UInt64(USED)
dev.queues[0].enabled = 1

// Chain at head 0: hdr(out,16) -> data(write,512) -> status(write,1)
desc(DESC, 0, 0x8000, 16, 1, 1)      // NEXT
desc(DESC, 1, 0x9000, 512, 3, 2)     // WRITE|NEXT
desc(DESC, 2, 0xA000, 1, 2, 0)       // WRITE
// Single descriptor at head 3: one out segment
desc(DESC, 3, 0xB000, 16, 0, 0)

// avail: idx=1, entry[0]=0
w16(AVAIL + 0, 0)        // flags
w16(AVAIL + 2, 1)        // idx
w16(AVAIL + 4, 0)        // entry[0] = head 0

var fails = 0
func check(_ name: String, _ cond: Bool) {
    print("\(cond ? "PASS" : "FAIL"): \(name)")
    if !cond { fails += 1 }
}

let e1 = dev.virtqPop(0)
check("pop#1 returns an element", e1 != nil)
check("pop#1 head == 0 (avail entry[0])", e1?.head == 0)
check("pop#1 walks the full 3-desc chain", e1?.segs.count == 3)
if let e1 { dev.virtqPush(0, e1, written: 513) }
check("used ring idx == 1 after push", r16(USED + 2) == 1)
check("used entry[0].id == 0", r32(USED + 4) == 0)

// Second submission: idx=2, entry[1]=3
w16(AVAIL + 2, 2)
w16(AVAIL + 6, 3)        // entry[1] = head 3
let e2 = dev.virtqPop(0)
check("pop#2 returns an element", e2 != nil)
check("pop#2 head == 3 (avail entry[1])", e2?.head == 3)
check("pop#2 single segment", e2?.segs.count == 1)
if let e2 { dev.virtqPush(0, e2, written: 0) }
check("used entry[1].id == 3", r32(USED + 4 + 8) == 3)

print(fails == 0 ? "ALL PASS" : "\(fails) FAILURES")
exit(fails == 0 ? 0 : 1)
