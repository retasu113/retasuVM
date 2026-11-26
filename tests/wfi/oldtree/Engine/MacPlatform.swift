import Foundation

/// Apple Silicon Mac プラットフォームのブート基盤。
///
/// iBoot からカーネルへの受け渡しを再現する:
/// - デバイスツリー（ADT）を RAM + 1 MiB に配置する
/// - カーネルは EL1 / MMU 無効で開始し、X0 = ADT の物理アドレスを受け取る
/// - 割り込みは AIC + FIQ で配送する（ARM64CPU.Platform.appleSilicon）
///
/// 対象はブート環境までで、Apple 純正の iBoot / XNU 自体はまだ起動しない
/// （リストア手順・SEP などが別途必要）。
enum MacPlatform {
    /// ADT の配置アドレス（RAM 先頭 + 1 MiB）。
    static var adtAddress: UInt64 { ARM64CPU.ramBase + 0x10_0000 }

    /// プラットフォームの ADT を構築する。
    static func buildDeviceTree(memorySize: Int) -> [UInt8] {
        var root = ADTNode("device-tree")
        root.setString("model", "Apple Virtual Machine 1")
        root.setStringList("compatible", ["apple,arm64-virtual", "apple,virtual-machine"])
        root.setU32("#address-cells", 2)
        root.setU32("#size-cells", 2)

        var chosen = ADTNode("chosen")
        chosen.setString("boot-args", "-v serial=1")
        chosen.setString("firmware-version", "retasuVM")
        root.children.append(chosen)

        var memory = ADTNode("memory")
        memory.setReg(address: ARM64CPU.ramBase, size: UInt64(memorySize))
        root.children.append(memory)

        var cpus = ADTNode("cpus")
        var cpu0 = ADTNode("cpu")
        cpu0.setStringList("compatible", ["apple,cpu", "arm,armv8"])
        cpu0.setU32("reg", 0)
        cpu0.setString("state", "running")
        cpus.children.append(cpu0)
        root.children.append(cpus)

        var armIO = ADTNode("arm-io")

        var aic = ADTNode("aic")
        aic.setStringList("compatible", ["apple,aic", "apple,aic,1"])
        aic.setReg(address: ARM64CPU.aicBase, size: 0x8000)
        aic.setEmpty("interrupt-controller")
        aic.setU32("#interrupt-cells", 3)
        armIO.children.append(aic)

        var uart = ADTNode("uart0")
        uart.setStringList("compatible", ["apple,uart", "arm,pl011"])
        uart.setReg(address: ARM64CPU.uartBase, size: 0x1000)
        uart.setU32("interrupts", UInt32(ARM64CPU.aicUARTIRQ))
        armIO.children.append(uart)

        var nvme = ADTNode("nvme")
        nvme.setStringList("compatible", ["apple,nvme", "nvme"])
        nvme.setReg(address: ARM64CPU.nvmeBase, size: 0x10000)
        nvme.setU32("interrupts", UInt32(ARM64CPU.aicNVMeIRQ))
        armIO.children.append(nvme)

        var timer = ADTNode("timer")
        timer.setStringList("compatible", ["arm,armv8-timer"])
        timer.setU32("clock-frequency", 62_500_000)
        armIO.children.append(timer)

        root.children.append(armIO)
        return root.serialized()
    }

    /// ADT を CPU の RAM へ配置し、プラットフォームを Apple Silicon 方式へ切り替える。
    /// 配置できなかった場合は false（呼び出し側は X0 を設定してはいけない）。
    @discardableResult
    static func installDeviceTree(cpu: ARM64CPU) -> Bool {
        cpu.platform = .appleSilicon
        let adt = buildDeviceTree(memorySize: cpu.memorySize)
        let offset = Int(adtAddress - ARM64CPU.ramBase)
        guard offset >= 0 && offset + adt.count <= cpu.memory.count else { return false }
        cpu.memory.replaceSubrange(offset..<(offset + adt.count), with: adt)
        return true
    }

    /// ELF64 カーネルを読み込み、Mac ブート方式で開始できる状態にする（X0 = ADT）。
    static func bootELF(cpu: ARM64CPU, elf: [UInt8]) throws {
        _ = try cpu.loadELF64(elf)
        // ADT が置けていないのに X0 だけ設定すると、ゲストはゴミをデバイスツリーとして読む
        precondition(installDeviceTree(cpu: cpu), "ADT を RAM へ配置できませんでした")
        cpu.setBootArgument(adtAddress)
    }
}
