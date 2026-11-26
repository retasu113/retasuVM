import Foundation

/// ACPI テーブルの生成（RSDP / XSDT / RSDT / FADT / DSDT / MADT）。
///
/// 実機と同じく BIOS 領域（0xE0000〜）にテーブルを配置する。ゲスト OS は
/// RSDP を走査して XSDT / RSDT から FADT と MADT を辿り、DSDT の
/// ポインタと APIC の構成（LAPIC / IOAPIC のアドレス）を得る。
/// DSDT の AML は最小限（\_SB.PCI0 の宣言のみ）で、電源管理や
/// メソッド評価までは扱わない。
enum X86ACPI {
    static let rsdpAddress = 0xE0000
    static let xsdtAddress = 0xE1000
    static let rsdtAddress = 0xE1100
    static let fadtAddress = 0xE1200
    static let dsdtAddress = 0xE1400
    static let madtAddress = 0xE1800
    static let hpetAddress = 0xE1A00

    private static let oemID = "RETASU"
    private static let oemTableID = "RETASUVM"

    /// テーブル一式をゲストメモリへ配置する（全ブート経路で呼ぶ）。
    static func install(cpu: X86CPU) {
        let dsdt = buildDSDT()
        let fadt = buildFADT(dsdtAddress: dsdtAddress)
        let madt = buildMADT()
        let hpet = buildHPET()
        let xsdt = buildSDT(signature: "XSDT", revision: 1, entries: [fadtAddress, madtAddress, hpetAddress], entrySize: 8)
        let rsdt = buildSDT(signature: "RSDT", revision: 1, entries: [fadtAddress, madtAddress, hpetAddress], entrySize: 4)
        cpu.loadData(xsdt, at: xsdtAddress)
        cpu.loadData(rsdt, at: rsdtAddress)
        cpu.loadData(fadt, at: fadtAddress)
        cpu.loadData(dsdt, at: dsdtAddress)
        cpu.loadData(madt, at: madtAddress)
        cpu.loadData(hpet, at: hpetAddress)
        cpu.loadData(buildRSDP(), at: rsdpAddress)
        X86SMBIOS.install(cpu: cpu)
    }

    // MARK: - RSDP

    private static func buildRSDP() -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 36)
        bytes.replaceSubrange(0..<8, with: [UInt8]("RSD PTR ".utf8))
        bytes.replaceSubrange(10..<16, with: padded(oemID, 6))
        bytes[8] = 0 // チェックサム（後で設定）
        bytes[9] = 2 // リビジョン（ACPI 2.0）
        write32(&bytes, at: 16, UInt32(rsdtAddress))
        write32(&bytes, at: 20, 36) // 全長
        write64(&bytes, at: 24, UInt64(xsdtAddress))
        // 基本チェックサム（先頭 20 バイト）を先に確定し、その後に
        // 全体を対象とする拡張チェックサムを求める
        bytes[8] = checksum(bytes, count: 20, excluding: 8)
        bytes[32] = checksum(bytes, count: 36, excluding: 32)
        return bytes
    }

    // MARK: - SDT（XSDT / RSDT）

    private static func buildSDT(signature: String, revision: UInt8, entries: [Int], entrySize: Int) -> [UInt8] {
        var bytes = sdtHeader(signature: signature, length: 36 + entries.count * entrySize, revision: revision)
        for entry in entries {
            if entrySize == 8 {
                append64(&bytes, UInt64(entry))
            } else {
                append32(&bytes, UInt32(entry))
            }
        }
        finalizeChecksum(&bytes)
        return bytes
    }

    // MARK: - FADT

    private static func buildFADT(dsdtAddress: Int) -> [UInt8] {
        var bytes = sdtHeader(signature: "FACP", length: 244, revision: 3)
        bytes += [UInt8](repeating: 0, count: 244 - 36)
        write32(&bytes, at: 40, UInt32(dsdtAddress)) // DSDT ポインタ
        bytes[45] = 0 // Preferred PM Profile: 未指定
        write16(&bytes, at: 46, 9) // SCI 割り込み
        // PM ブロック（I/O ポートの番地だけ用意し、レジスタ自体は未実装）
        write32(&bytes, at: 56, 0x400) // PM1a EVT
        write32(&bytes, at: 64, 0x404) // PM1a CNT
        write32(&bytes, at: 76, 0x408) // PM TMR
        write32(&bytes, at: 80, 0x420) // GPE0
        write16(&bytes, at: 90, 101) // P_LVL2_LAT
        write16(&bytes, at: 92, 1001) // P_LVL3_LAT
        write16(&bytes, at: 103, 0x0003) // IAPC_BOOT_ARCH: レガシーデバイス + 8042
        write32(&bytes, at: 106, 0x00000401) // Flags: WBINVD + RESET_REG_SUP
        // RESET_REG（I/O ポート 0xCF9、値 0x06 = ハードリセット相当）
        bytes[110] = 1 // Address Space: I/O
        bytes[111] = 8 // Bit Width
        bytes[112] = 0 // Bit Offset
        bytes[113] = 1 // Access Size: バイト
        write64(&bytes, at: 114, 0xCF9)
        bytes[122] = 0x06 // RESET_VALUE
        write64(&bytes, at: 134, UInt64(dsdtAddress)) // X_DSDT
        finalizeChecksum(&bytes)
        return bytes
    }

    // MARK: - MADT

    private static func buildMADT() -> [UInt8] {
        var bytes = sdtHeader(signature: "APIC", length: 0, revision: 3)
        append32(&bytes, 0xFEE00000) // Local APIC アドレス
        append32(&bytes, 1) // Flags: PCAT_COMPAT（デュアル PIC あり）
        // Processor Local APIC（ACPI ID 0 / APIC ID 0、有効）
        bytes += [0, 8, 0, 0]
        append32(&bytes, 1)
        // I/O APIC（ID 0、アドレス 0xFEC00000、GSI ベース 0）
        bytes += [1, 12, 0, 0]
        append32(&bytes, 0xFEC00000)
        append32(&bytes, 0)
        // Interrupt Source Override（ISA IRQ0 → GSI 2）
        bytes += [2, 10, 0, 0]
        append32(&bytes, 2)
        bytes += [0, 0]
        write32(&bytes, at: 4, UInt32(bytes.count))
        finalizeChecksum(&bytes)
        return bytes
    }

    // MARK: - HPET

    private static func buildHPET() -> [UInt8] {
        var bytes = sdtHeader(signature: "HPET", length: 56, revision: 1)
        bytes += [UInt8](repeating: 0, count: 56 - 36)
        write32(&bytes, at: 36, 0x8086A201) // イベントタイマブロック ID
        // Base Address (GAS): メモリ空間、0xFED00000
        write64(&bytes, at: 44, 0xFED00000)
        write16(&bytes, at: 53, 0x0080) // 最小クロックチック
        finalizeChecksum(&bytes)
        return bytes
    }

    // MARK: - DSDT（最小 AML）

    private static func buildDSDT() -> [UInt8] {
        // Scope (\\_SB) { Device (PCI0) {...} Device (HPET) {...} Device (SMC_) {...} }
        var pciBody: [UInt8] = [UInt8]("PCI0".utf8)
        pciBody += nameAML("_HID", eisaID("PNP0A08"))
        pciBody += nameAML("_CID", eisaID("PNP0A03"))
        pciBody += [0x08] + [UInt8]("_UID".utf8) + [0x0A, 0x00]

        var hpetBody: [UInt8] = [UInt8]("HPET".utf8)
        hpetBody += nameAML("_HID", eisaID("PNP0103"))
        hpetBody += [0x08] + [UInt8]("_UID".utf8) + [0x0A, 0x00]
        // _CRS: Memory32Fixed (ReadWrite, 0xFED00000, 0x400)
        var template: [UInt8] = [0x86, 0x09, 0x00, 0x01]
        append32(&template, 0xFED00000)
        append32(&template, 0x400)
        template += [0x79, 0x00] // EndTag
        var crs: [UInt8] = [0x08] + [UInt8]("_CRS".utf8)
        crs += [0x11] + pkgLength(template.count + 2) + [0x0A, UInt8(template.count)] + template
        hpetBody += crs

        var smcBody: [UInt8] = [UInt8]("SMC_".utf8)
        smcBody += nameAML("_HID", eisaID("APP0001"))

        var scopeBody: [UInt8] = [0x5C, 0x5F, 0x53, 0x42] // "\\_SB"
        scopeBody += deviceAML(pciBody)
        scopeBody += deviceAML(hpetBody)
        scopeBody += deviceAML(smcBody)
        let aml: [UInt8] = [0x10] + pkgLength(scopeBody.count) + scopeBody
        var bytes = sdtHeader(signature: "DSDT", length: 36 + aml.count, revision: 2)
        bytes += aml
        finalizeChecksum(&bytes)
        return bytes
    }

    private static func deviceAML(_ body: [UInt8]) -> [UInt8] {
        [0x5B, 0x82] + pkgLength(body.count) + body // DeviceOp
    }

    /// AML の PkgLength（長さフィールド自体を含む総長をエンコードする）。
    private static func pkgLength(_ bodyCount: Int) -> [UInt8] {
        if bodyCount + 1 < 64 {
            return [UInt8(bodyCount + 1)]
        }
        let total = bodyCount + 2
        return [0x40 | UInt8(total & 0x0F), UInt8((total >> 4) & 0xFF)]
    }
    private static func nameAML(_ name: String, _ value: [UInt8]) -> [UInt8] {
        [0x08] + [UInt8](name.utf8) + value
    }

    /// EisaId() の DWORD エンコーディング（DWordPrefix + 圧縮 ID）。
    private static func eisaID(_ id: String) -> [UInt8] {
        let chars = [UInt8](id.utf8)
        let letters = (UInt32(chars[0] - 0x40) << 10) | (UInt32(chars[1] - 0x40) << 5) | UInt32(chars[2] - 0x40)
        let product = UInt32(id.dropFirst(3), radix: 16) ?? 0
        var bytes: [UInt8] = [0x0C] // DWordPrefix
        append32(&bytes, (letters << 16) | product)
        return bytes
    }

    // MARK: - 共通

    private static func sdtHeader(signature: String, length: Int, revision: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 36)
        bytes.replaceSubrange(0..<4, with: [UInt8](signature.utf8))
        write32(&bytes, at: 4, UInt32(length))
        bytes[8] = revision
        bytes.replaceSubrange(10..<16, with: padded(oemID, 6))
        bytes.replaceSubrange(16..<24, with: padded(oemTableID, 8))
        write32(&bytes, at: 24, 1) // OEM リビジョン
        bytes.replaceSubrange(28..<32, with: [UInt8]("RETA".utf8)) // Creator ID
        write32(&bytes, at: 32, 1) // Creator リビジョン
        return bytes
    }

    private static func padded(_ string: String, _ length: Int) -> [UInt8] {
        var bytes = [UInt8](string.utf8.prefix(length))
        while bytes.count < length { bytes.append(0x20) }
        return bytes
    }

    /// 全バイト合計が 0 になるチェックサム値を求める（対象位置を除く）。
    private static func checksum(_ bytes: [UInt8], count: Int, excluding index: Int) -> UInt8 {
        var sum = 0
        for i in 0..<count where i != index {
            sum += Int(bytes[i])
        }
        return UInt8((256 - (sum % 256)) % 256)
    }

    private static func finalizeChecksum(_ bytes: inout [UInt8]) {
        bytes[9] = 0
        bytes[9] = checksum(bytes, count: bytes.count, excluding: 9)
    }

    private static func write16(_ bytes: inout [UInt8], at offset: Int, _ value: UInt16) {
        bytes[offset] = UInt8(value & 0xFF)
        bytes[offset + 1] = UInt8((value >> 8) & 0xFF)
    }

    private static func write32(_ bytes: inout [UInt8], at offset: Int, _ value: UInt32) {
        for i in 0..<4 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    private static func write64(_ bytes: inout [UInt8], at offset: Int, _ value: UInt64) {
        for i in 0..<8 { bytes[offset + i] = UInt8((value >> (8 * i)) & 0xFF) }
    }

    private static func append32(_ bytes: inout [UInt8], _ value: UInt32) {
        for i in 0..<4 { bytes.append(UInt8((value >> (8 * i)) & 0xFF)) }
    }

    private static func append64(_ bytes: inout [UInt8], _ value: UInt64) {
        for i in 0..<8 { bytes.append(UInt8((value >> (8 * i)) & 0xFF)) }
    }
}
