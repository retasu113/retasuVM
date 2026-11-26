import sys

p = 'src_vioprobe/VMApplePCIe.swift'
s = open(p).read()

# 1) log in virtqPop right after head is computed
old = """        let headSlot = 2 + Int(q.lastAvail % q.size) * 2
        let head = UInt16(hdr[headSlot]) | UInt16(hdr[headSlot + 1]) << 8"""
new = """        let headSlot = 2 + Int(q.lastAvail % q.size) * 2
        let head = UInt16(hdr[headSlot]) | UInt16(hdr[headSlot + 1]) << 8
        if pci.get16(0x02) == 0x1A00 {
            let eo = 4 + Int(q.lastAvail % q.size) * 2
            let rawEntry = UInt16(hdr[eo]) | UInt16(hdr[eo + 1]) << 8
            FileHandle.standardError.write("[vioprobe] pop slot=\\(pci.slot) q=\\(qi) lastAvail=\\(q.lastAvail) availIdx=\\(idx) entryAtCorrectOffset=\\(rawEntry) chosenHead=\\(head)\\n".data(using: .utf8)!)
        }"""
assert old in s, "pop anchor missing"
s = s.replace(old, new)

# 2) log in virtqPush
old2 = """    func virtqPush(_ qi: Int, _ e: VirtqElem, written: UInt32) {
        var q = queues[qi]"""
new2 = """    func virtqPush(_ qi: Int, _ e: VirtqElem, written: UInt32) {
        if pci.get16(0x02) == 0x1A00 {
            FileHandle.standardError.write("[vioprobe] push slot=\\(pci.slot) q=\\(qi) head=\\(e.head) written=\\(written)\\n".data(using: .utf8)!)
        }
        var q = queues[qi]"""
assert old2 in s, "push anchor missing"
s = s.replace(old2, new2)

# 3) log in interrupt()
old3 = """    func interrupt() {
        isr |= 1"""
new3 = """    func interrupt() {
        if pci.get16(0x02) == 0x1A00 {
            FileHandle.standardError.write("[vioprobe] interrupt slot=\\(pci.slot)\\n".data(using: .utf8)!)
        }
        isr |= 1"""
assert old3 in s, "interrupt anchor missing"
s = s.replace(old3, new3)

open(p, 'w').write(s)
print('patched ok')
