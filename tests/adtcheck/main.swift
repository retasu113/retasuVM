import Foundation
let kc = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: "/home/hatch/workspace/retasuvm/ipsw/kernelcache.macho")))
let dt = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: "/home/hatch/workspace/retasuvm/ipsw/devicetree.bin")))
let cpu = ARM64CPU(memorySize: 2048 * 1024 * 1024)
let info = try! VMAppleBoot.prepare(cpu: cpu, kernelcache: kc, deviceTree: dt, commandLine: "-v serial=3")
var out = [UInt8]()
out.reserveCapacity(70000)
let adtLen = Int(cpu.readGuestMemory(address: info.bootArgsPA + 0x68, size: 4) & 0xFFFFFFFF)
for i in 0..<adtLen {
    out.append(UInt8(cpu.readGuestMemory(address: info.deviceTreePA + UInt64(i), size: 1) & 0xFF))
}
try! Data(out).write(to: URL(fileURLWithPath: "/home/hatch/workspace/retasuvm/tests/adtcheck/adt_out.bin"))
print("adt dumped", out.count, "bytes")
