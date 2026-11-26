import Foundation

/// VMAPPLE（VirtualMac2,1）向けの XNU 直接ブートローダ。
///
/// iBoot を介さず、IPSW から取り出した kernelcache（LZFSE 展開済みの
/// MH_FILESET Mach-O）と実デバイスツリー（ADT）を使い、iBoot が用意する
/// 起動環境をエミュレータ側で合成する:
/// - カーネルキャッシュを DRAM 先頭（physBase）にスライド 0 で配置
/// - ADT をパッチ（メモリ範囲、CPU を 1 個に剪定、chosen/boot-args、random-seed）
/// - boot_args v2（0x2E0 バイト）を構築し、X0 = boot_args でエントリへ跳ぶ
enum VMAppleBootError: Error, CustomStringConvertible {
    case badKernelcache(String)
    case badDeviceTree(String)
    case outOfMemory

    var description: String {
        switch self {
        case .badKernelcache(let d): return "VMApple: kernelcache が不正です（\(d)）"
        case .badDeviceTree(let d): return "VMApple: DeviceTree が不正です（\(d)）"
        case .outOfMemory: return "VMApple: 配置先メモリが不足しています"
        }
    }
}

struct VMAppleBootInfo {
    /// 実行開始物理アドレス
    let entryPA: UInt64
    let bootArgsPA: UInt64
    let deviceTreePA: UInt64
    let topOfKernelData: UInt64
    /// arm-io 内デバイスの物理アドレス（GIC / UART の配置確認用）
    let gicDistPA: UInt64
    let gicRedistPA: UInt64
    let uartPA: UInt64
}

enum VMAppleBoot {
    /// VMAPPLE の DRAM ベース（Apple Virtualization / QEMU vmapple と同じ）
    static let dramBase: UInt64 = 0x7000_0000
    /// ADT の ranges が示す arm-io ウィンドウの物理ベース
    static let armIOBase: UInt64 = 0x1000_0000

    private static func align16K(_ value: UInt64) -> UInt64 {
        (value + 0x3FFF) & ~0x3FFF
    }

    // MARK: - ADT パース

    private static func readU32(_ data: [UInt8], _ off: Int) -> UInt32 {
        UInt32(data[off]) | UInt32(data[off + 1]) << 8 | UInt32(data[off + 2]) << 16 | UInt32(data[off + 3]) << 24
    }

    private static func cString(_ bytes: ArraySlice<UInt8>) -> String {
        let end = bytes.firstIndex(of: 0) ?? bytes.endIndex
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    /// ADT バイナリを ADTNode ツリーへ変換する（"name" プロパティはノード名へ吸収）。
    static func parseADT(_ data: [UInt8]) -> ADTNode? {
        var offset = 0
        return parseADTNode(data, &offset)
    }

    private static func parseADTNode(_ data: [UInt8], _ offset: inout Int) -> ADTNode? {
        guard offset + 8 <= data.count else { return nil }
        let propCount = Int(readU32(data, offset))
        let childCount = Int(readU32(data, offset + 4))
        offset += 8
        var name = ""
        var properties: [(name: String, value: [UInt8])] = []
        for _ in 0..<propCount {
            guard offset + 36 <= data.count else { return nil }
            let propName = cString(data[offset..<(offset + 32)])
            let size = readU32(data, offset + 32)
            let length = Int(size & 0x7FFF_FFFF)
            guard offset + 36 + length <= data.count else { return nil }
            let value = Array(data[(offset + 36)..<(offset + 36 + length)])
            offset += 36 + ((length + 3) & ~3)
            if propName == "name" {
                name = cString(value[...])
            } else {
                properties.append((propName, value))
            }
        }
        var node = ADTNode(name)
        node.properties = properties
        for _ in 0..<childCount {
            guard let child = parseADTNode(data, &offset) else { return nil }
            node.children.append(child)
        }
        return node
    }

    // MARK: - kernelcache 解析

    private struct KernelcacheLayout {
        let staticBase: UInt64
        let entryVA: UInt64
    }

    private static func parseKernelcache(_ data: [UInt8]) throws -> KernelcacheLayout {
        func u32(_ off: Int) -> UInt32 {
            UInt32(data[off]) | UInt32(data[off + 1]) << 8 | UInt32(data[off + 2]) << 16 | UInt32(data[off + 3]) << 24
        }
        func u64(_ off: Int) -> UInt64 { UInt64(u32(off)) | UInt64(u32(off + 4)) << 32 }
        guard data.count >= 32 else { throw VMAppleBootError.badKernelcache("小さすぎます") }
        guard u32(0) == 0xFEED_FACF else { throw VMAppleBootError.badKernelcache("Mach-O 64 ではありません") }
        let filetype = u32(12)
        guard filetype == 12 else { throw VMAppleBootError.badKernelcache("MH_FILESET ではありません（filetype=\(filetype)）") }
        let ncmds = Int(u32(16))
        var off = 32
        var staticBase: UInt64 = UInt64.max
        var entryVA: UInt64 = 0
        for _ in 0..<ncmds {
            guard off + 8 <= data.count else { throw VMAppleBootError.badKernelcache("ロードコマンドが範囲外です") }
            let cmd = u32(off)
            let cmdsize = Int(u32(off + 4))
            guard cmdsize >= 8, off + cmdsize <= data.count else { throw VMAppleBootError.badKernelcache("ロードコマンドサイズが不正です") }
            if cmd == 0x19 { // LC_SEGMENT_64（構造体は 72 バイト）
                guard cmdsize >= 72 else { throw VMAppleBootError.badKernelcache("LC_SEGMENT_64 が小さすぎます") }
                let vmaddr = u64(off + 24)
                let vmsize = u64(off + 32)
                if vmsize > 0 {
                    staticBase = min(staticBase, vmaddr)
                }
            } else if cmd == 0x5 { // LC_UNIXTHREAD（コンテナ側が本物のエントリ）
                // state[32] が pc（x0...x28, fp, lr, sp の次）= オフセット 272 から読む
                guard cmdsize >= 280 else { throw VMAppleBootError.badKernelcache("LC_UNIXTHREAD が小さすぎます") }
                entryVA = u64(off + 16 + 32 * 8)
            }
            off += cmdsize
        }
        guard staticBase != UInt64.max, entryVA != 0 else {
            throw VMAppleBootError.badKernelcache("セグメントまたはエントリが見つかりません")
        }
        return KernelcacheLayout(staticBase: staticBase, entryVA: entryVA)
    }

    // MARK: - 起動準備

    /// CPU へ kernelcache と ADT を配置し、boot_args を構築して実行開始状態にする。
    /// CPU は事前に platform = .vmApple 相当へ設定されている前提（メモリ確保済み）。
    static func prepare(cpu: ARM64CPU, kernelcache: [UInt8], deviceTree: [UInt8],
                        commandLine: String) throws -> VMAppleBootInfo {
        let layout = try parseKernelcache(kernelcache)
        guard var root = parseADT(deviceTree) else {
            throw VMAppleBootError.badDeviceTree("ADT のパースに失敗しました")
        }
        let memorySize = UInt64(cpu.memorySize)

        // --- ADT パッチ ---
        // /memory: DRAM 範囲
        root.withChild("memory") { node in
            node.setReg(address: dramBase, size: memorySize)
        }
        // /cpus: cpu0 のみに剪定（GIC 再配布器の数と CPU 数を一致させる）
        root.withChild("cpus") { node in
            node.children = node.children.filter { $0.name == "cpu0" }
        }
        // /chosen: boot-args と random-seed
        var rng = SystemRandomNumberGenerator()
        var seed = (0..<64).map { _ in UInt8.random(in: 0...255, using: &rng) }
        // テスト用: 環境変数 VMAPPLE_FIXED_SEED (0-255) があれば決定論的な seed に差し替える
        if let fixed = ProcessInfo.processInfo.environment["VMAPPLE_FIXED_SEED"],
           let byte = UInt8(fixed) {
            seed = [UInt8](repeating: byte, count: 64)
        }
        root.withChild("chosen") { node in
            node.setString("boot-args", commandLine)
            node.setBytes("random-seed", seed)
            // arm_init が /chosen から読む DRAM 情報（iBoot が設定するもの）。
            // 値はいずれもリトルエンディアンの u64 として読み取られる。
            var baseBytes = [UInt8](repeating: 0, count: 8)
            var sizeBytes = [UInt8](repeating: 0, count: 8)
            for i in 0..<8 {
                baseBytes[i] = UInt8((dramBase >> (8 * i)) & 0xFF)
                sizeBytes[i] = UInt8((memorySize >> (8 * i)) & 0xFF)
            }
            node.setBytes("dram-base", baseBytes)
            node.setBytes("dram-size", sizeBytes)
            // /chosen/iBoot の時刻プロパティ（テンプレートでは全て 0）。
            // iBoot が実測値を入れるもので、0 のままだとブート進捗の計算が
            // ゼロ除算的な退化ループに入るため、24MHz タイムベースでの
            // もっともらしい値を設定する（単位: ticks）。
            node.withChild("iBoot") { iboot in
                func u32le(_ v: UInt32) -> [UInt8] {
                    [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
                }
                iboot.setBytes("start-time", u32le(24_000_000))
                iboot.setBytes("debug-wait-start", u32le(24_000_000))
                iboot.setBytes("load-kernel-start", u32le(48_000_000))
                iboot.setBytes("populate-registry-time", u32le(1_200_000))
            }
        }
        // /filesystems/DoNotUseSEP（macOS 15+ で必須。QEMU vmapple の
        // 15.6.1 対応パッチと同形式）: ルートの子ノード "filesystems" に
        // u32 プロパティ DoNotUseSEP = 1 を持たせる。SEP が無い環境で
        // APFS が暗号化されていない Data ボリュームをマウントできるようにする。
        if var fs = root.children.first(where: { $0.name == "filesystems" }) {
            // 既存ノードにも必ずプロパティを持たせる
            fs.setBytes("DoNotUseSEP", [1, 0, 0, 0])
            if let idx = root.children.firstIndex(where: { $0.name == "filesystems" }) {
                root.children[idx] = fs
            }
        } else {
            var fs = ADTNode("filesystems")
            fs.setBytes("DoNotUseSEP", [1, 0, 0, 0])
            root.children.append(fs)
        }
        let adt = root.serialized()

        // --- GIC / UART の物理アドレスを ADT から求める ---
        var gicDistPA: UInt64 = 0
        var gicRedistPA: UInt64 = 0
        var uartPA: UInt64 = 0
        if let armIO = root.children.first(where: { $0.name == "arm-io" }) {
            func regPairs(_ node: ADTNode) -> [(UInt64, UInt64)] {
                guard let value = node.properties.first(where: { $0.name == "reg" })?.value else { return [] }
                var pairs: [(UInt64, UInt64)] = []
                var i = 0
                while i + 16 <= value.count {
                    var addr: UInt64 = 0
                    var size: UInt64 = 0
                    for j in 0..<8 {
                        addr |= UInt64(value[i + j]) << (8 * j)
                        size |= UInt64(value[i + 8 + j]) << (8 * j)
                    }
                    pairs.append((addr, size))
                    i += 16
                }
                return pairs
            }
            if let gic = armIO.children.first(where: { $0.name == "gic" }) {
                let pairs = regPairs(gic)
                if pairs.count >= 1 { gicDistPA = armIOBase + pairs[0].0 }
                if pairs.count >= 2 { gicRedistPA = armIOBase + pairs[1].0 }
            }
            if let uart = armIO.children.first(where: { $0.name == "uart0" }) {
                let pairs = regPairs(uart)
                if let first = pairs.first { uartPA = armIOBase + first.0 }
            }
        }

        // --- 物理レイアウト ---
        // XNU の start はイメージを 32MiB ブロック単位でブロックマップする。
        // 静的 VA ベース（0x...7004000）のブロック内オフセット（0x1004000）と
        // ロード PA のブロック内オフセットが一致しないとマッピングがずれるため、
        // KC は DRAM 先頭ではなくそのオフセット分ずらして配置する。
        let kcPA = dramBase + (layout.staticBase & 0x1FF_FFFF)
        let kcSize = align16K(UInt64(kernelcache.count))
        let adtPA = kcPA + kcSize
        let adtSize = align16K(UInt64(adt.count))
        let bootArgsPA = adtPA + adtSize
        let topOfKernelData = align16K(bootArgsPA + 0x2E0)
        guard topOfKernelData + 0x10_0000 <= dramBase + memorySize else {
            throw VMAppleBootError.outOfMemory
        }

        // --- 配置 ---
        cpu.ramBaseAddress = dramBase   // 以後の物理アクセスの基準を DRAM ベースに合わせる
        cpu.writeGuestMemory(kernelcache, at: kcPA)
        cpu.writeGuestMemory(adt, at: adtPA)

        // --- boot_args v2 ---
        var args = [UInt8](repeating: 0, count: 0x2E0)
        func put16(_ off: Int, _ v: UInt16) {
            args[off] = UInt8(v & 0xFF); args[off + 1] = UInt8((v >> 8) & 0xFF)
        }
        func put32(_ off: Int, _ v: UInt32) {
            for i in 0..<4 { args[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }
        func put64(_ off: Int, _ v: UInt64) {
            for i in 0..<8 { args[off + i] = UInt8((v >> (8 * i)) & 0xFF) }
        }
        put16(0x00, 1)                       // Revision
        put16(0x02, 2)                       // Version
        let virtBase = layout.staticBase - (kcPA - dramBase)
        put64(0x08, virtBase)                // virtBase（PA dramBase に対応する VA）
        put64(0x10, dramBase)                // physBase（DRAM 先頭。phystokv の合法範囲の起点）
        put64(0x18, memorySize)              // memSize
        put64(0x20, topOfKernelData)         // topOfKernelData
        // Video（0x28...0x58）はゼロ = ディスプレイなし
        put32(0x58, 0)                       // machineType
        // deviceTreeP: XNU の DT ライブラリはこのポインタをそのままデリファレンスする。
        // pmap_bootstrap が TTBR0 を空テーブルに切り替えた後もアクセスできるよう、
        // PA ではなく physmap VA（phystokv(adtPA)）を渡す必要がある。
        put64(0x60, virtBase + (adtPA - dramBase))  // deviceTreeP（physmap VA）
        put32(0x68, UInt32(adt.count))       // deviceTreeLength
        let cmd = [UInt8](commandLine.utf8)
        for (i, b) in cmd.prefix(607).enumerated() { args[0x6C + i] = b }
        put64(0x2D0, 0)                      // bootFlags
        put64(0x2D8, memorySize)             // memSizeActual
        cpu.writeGuestMemory(args, at: bootArgsPA)

        // --- 実行開始状態 ---
        let entryPA = kcPA + (layout.entryVA - layout.staticBase)
        cpu.setupVMAppleEntry(pc: entryPA, bootArgsPA: bootArgsPA,
                              stackTop: topOfKernelData + 0x10_0000,
                              gicDistPA: gicDistPA, gicRedistPA: gicRedistPA, uartPA: uartPA)
        return VMAppleBootInfo(entryPA: entryPA, bootArgsPA: bootArgsPA,
                               deviceTreePA: adtPA, topOfKernelData: topOfKernelData,
                               gicDistPA: gicDistPA, gicRedistPA: gicRedistPA, uartPA: uartPA)
    }
}

extension ADTNode {
    /// 名前で子ノードを探して変更する。
    mutating func withChild(_ name: String, _ body: (inout ADTNode) -> Void) {
        if let index = children.firstIndex(where: { $0.name == name }) {
            body(&children[index])
        }
    }
}
