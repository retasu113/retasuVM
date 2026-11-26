import Foundation

func decode(_ json: String) -> [VirtualMachine]? {
    try? JSONDecoder().decode([VirtualMachine].self, from: Data(json.utf8))
}

// 1. 未知の enum 値（将来のバージョンが書いたファイル）
let future = """
[{"id":"11111111-1111-1111-1111-111111111111","name":"将来のVM","configuration":{"cpuCount":4,"memoryMB":8192,"diskGB":64,"architecture":"sparc","guestOS":"haiku","guestImage":"futureOS","useISO":true,"networkEnabled":true,"sharedFolderEnabled":false},"state":"suspended","createdAt":700000000.0}]
"""
if let vms = decode(future), vms.count == 1 {
    let vm = vms[0]
    print("future: name=\(vm.name) arch=\(vm.configuration.architecture) state=\(vm.state) cpu=\(vm.configuration.cpuCount)")
    print(vm.configuration.architecture == .riscv && vm.state == .stopped && vm.configuration.cpuCount == 4 ? "FUTURE OK" : "FUTURE NG")
} else { print("FUTURE NG (decode failed)") }

// 2. 型の不一致（数値が文字列）
let mistyped = """
[{"id":"22222222-2222-2222-2222-222222222222","name":"型違いVM","configuration":{"cpuCount":"3","memoryMB":"2048","diskGB":16,"architecture":"x86","guestOS":"linux","guestImage":"retasuOS","useISO":"true","networkEnabled":true,"sharedFolderEnabled":false},"state":"running","createdAt":700000000.0}]
"""
if let vms = decode(mistyped), vms.count == 1 {
    let vm = vms[0]
    print("mistyped: cpu=\(vm.configuration.cpuCount) mem=\(vm.configuration.memoryMB) useISO=\(vm.configuration.useISO) arch=\(vm.configuration.architecture)")
    print(vm.configuration.cpuCount == 3 && vm.configuration.memoryMB == 2048 && vm.configuration.useISO && vm.configuration.architecture == .x86 ? "MISTYPED OK" : "MISTYPED NG")
} else { print("MISTYPED NG (decode failed)") }

// 3. v0.1.0 時代の最小ファイル（キー欠落）
let legacy = """
[{"id":"33333333-3333-3333-3333-333333333333","name":"旧VM","configuration":{},"state":"stopped","createdAt":690000000.0}]
"""
if let vms = decode(legacy), vms.count == 1 {
    print("legacy: cpu=\(vms[0].configuration.cpuCount) arch=\(vms[0].configuration.architecture)")
    print(vms[0].configuration.cpuCount == 2 ? "LEGACY OK" : "LEGACY NG")
} else { print("LEGACY NG (decode failed)") }

// 4. 通常の往復（エンコード→デコードで値が保たれる）
let original = VirtualMachine(name: "往復VM", configuration: VMConfiguration(cpuCount: 6, memoryMB: 12288, diskGB: 128, architecture: .arm, guestOS: .other, guestImage: .calcOS, useISO: false, isoFileName: nil, isoDisplayName: nil, networkEnabled: false, sharedFolderEnabled: true), state: .error)
if let data = try? JSONEncoder().encode([original]),
   let back = try? JSONDecoder().decode([VirtualMachine].self, from: data), back.count == 1 {
    let vm = back[0]
    print(vm.name == "往復VM" && vm.configuration.cpuCount == 6 && vm.configuration.architecture == .arm && vm.configuration.guestImage == .calcOS && vm.state == .error && !vm.configuration.networkEnabled && vm.configuration.sharedFolderEnabled ? "ROUNDTRIP OK" : "ROUNDTRIP NG")
} else { print("ROUNDTRIP NG") }
