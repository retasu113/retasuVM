import Foundation

// VMAPPLE の PCIe ホストブリッジと virtio デバイス群。
// Henge devices/pcie.c / virtio.c / virtio_blk.c / virtio_usb.c の再現:
// ECAM 0x4000_0000（256 MiB）、MMIO ウィンドウ 0x5000_0000、INTx はスロット番号を
// そのまま INTID（ベース 64）に使う（スウィズルなし）。virtio はモダン（1.x）のみ、
// BAR4（16 KiB）に common / ISR / device / notify 領域を置く QEMU レイアウト。

// MARK: - PCI デバイス

final class PciDevice {
    var config = [UInt8](repeating: 0, count: 4096)
    var wmask = [UInt8](repeating: 0, count: 256)
    var barSize = [UInt64](repeating: 0, count: 6)
    var bar64 = [Bool](repeating: false, count: 6)
    var slot = -1
    var intxEffective = false
    weak var bus: PcieBus?
    var barRead: ((PciDevice, Int, UInt64, Int) -> UInt64)?
    var barWrite: ((PciDevice, Int, UInt64, UInt64, Int) -> Void)?
    var opaque: VirtioDevice?

    func put16(_ off: Int, _ v: UInt16) {
        config[off] = UInt8(v & 0xFF); config[off + 1] = UInt8((v >> 8) & 0xFF)
    }
    func put32(_ off: Int, _ v: UInt32) {
        for i in 0..<4 { config[off + i] = UInt8((v >> UInt32(8 * i)) & 0xFF) }
    }
    func get16(_ off: Int) -> UInt16 { UInt16(config[off]) | UInt16(config[off + 1]) << 8 }
    func get32(_ off: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v |= UInt32(config[off + i]) << UInt32(8 * i) }
        return v
    }

    func pciInit(vendor: UInt16, device: UInt16, classRev: UInt32, subVendor: UInt16, subId: UInt16) {
        config = [UInt8](repeating: 0, count: 4096)
        wmask = [UInt8](repeating: 0, count: 256)
        put16(0x00, vendor)
        put16(0x02, device)
        put32(0x08, classRev)
        put16(0x2C, subVendor)
        put16(0x2E, subId)
        config[0x3D] = 1   // INTA
        put16(0x04, 0)     // COMMAND は wmask 経由でのみ書ける
        wmask[0x04] = 0x07; wmask[0x05] = 0x04   // COMMAND: I/O, memory, bus master, INTx disable(bit10)
        wmask[0x0C] = 0xFF   // cache line size
        wmask[0x0D] = 0xFF   // latency timer
        wmask[0x3C] = 0xFF   // interrupt line
    }

    func addBar(_ bar: Int, size: UInt64, is64: Bool) {
        barSize[bar] = size
        bar64[bar] = is64
        put32(0x10 + bar * 4, is64 ? 0x4 : 0x0)
        let mask = ~(size - 1) & ~UInt64(0xF)   // 下位 4 ビットは属性ビット（書けない）
        for i in 0..<4 { wmask[0x10 + bar * 4 + i] = UInt8((mask >> UInt64(8 * i)) & 0xFF) }
        if is64 {
            let hi = UInt32(truncatingIfNeeded: mask >> 32)
            for i in 0..<4 { wmask[0x14 + bar * 4 + i] = UInt8((hi >> UInt32(8 * i)) & 0xFF) }
        }
    }

    func barAddr(_ bar: Int) -> UInt64 {
        var lo = UInt64(get32(0x10 + bar * 4) & ~0xF)
        if bar64[bar] { lo |= UInt64(get32(0x14 + bar * 4)) << 32 }
        return lo
    }

    /// INTx レベルを設定する（COMMAND.INTX_DISABLE でゲートし、STATUS.INTX は生レベルを反映）
    func setIntx(_ level: Bool) {
        guard let bus else { return }
        let cmd = get16(0x04)
        let eff = level && (cmd & 0x400) == 0
        var status = get16(0x06)
        status = level ? status | 0x8 : status & ~0x8
        put16(0x06, status)
        if eff == intxEffective { return }
        intxEffective = eff
        bus.lineCount[slot] += eff ? 1 : -1
        bus.updateLine(slot)
    }
}

// MARK: - PCIe バス

final class PcieBus {
    static let ecamBase: UInt64 = 0x4000_0000
    static let mmioBase: UInt64 = 0x5000_0000
    static let mmioSize: UInt64 = 0x1FFF_0000
    static let intxBase = 64   // INTID = 32 + VMAPPLE_IRQ_PCIE(0x20) + スロット

    var devices = [PciDevice?](repeating: nil, count: 32)
    var lineCount = [Int](repeating: 0, count: 32)
    let bridge = PciDevice()
    var setIRQ: (Int, Bool) -> Void = { _, _ in }

    init() {
        bridge.pciInit(vendor: 0x1B36, device: 0x0008, classRev: 0x0600_0000, subVendor: 0x1AF4, subId: 0x1100)
        attach(bridge)
    }

    @discardableResult
    func attach(_ d: PciDevice) -> Int {
        for s in 0..<32 where devices[s] == nil {
            devices[s] = d
            d.bus = self
            d.slot = s
            return s
        }
        return -1
    }

    func updateLine(_ line: Int) {
        setIRQ(PcieBus.intxBase + line, lineCount[line] > 0)
    }

    func ecamRead(offset: UInt64, size: Int) -> UInt64 {
        let bus = offset >> 20, slot = Int((offset >> 15) & 31), fn = (offset >> 12) & 7, reg = Int(offset & 0xFFF)
        guard bus == 0, fn == 0, let d = devices[slot] else {
            return size == 8 ? UInt64.max : (UInt64(1) << UInt64(size * 8)) - 1
        }
        var v: UInt64 = 0
        let n = min(size, 4096 - reg)
        for i in 0..<n { v |= UInt64(d.config[reg + i]) << UInt64(8 * i) }
        return v
    }

    func ecamWrite(offset: UInt64, value: UInt64, size: Int) {
        let bus = offset >> 20, slot = Int((offset >> 15) & 31), fn = (offset >> 12) & 7, reg = Int(offset & 0xFFF)
        guard bus == 0, fn == 0, let d = devices[slot] else { return }
        let oldCmd = d.get16(0x04)
        for i in 0..<size where reg + i < 256 {
            let w = d.wmask[reg + i]
            let b = UInt8((value >> UInt64(8 * i)) & 0xFF)
            d.config[reg + i] = (d.config[reg + i] & ~w) | (b & w)
        }
        if (oldCmd ^ d.get16(0x04)) & 0x400 != 0 {
            d.setIntx((d.get16(0x06) & 0x8) != 0)
        }
    }

    private func barLookup(pa: UInt64) -> (PciDevice, Int, UInt64)? {
        for s in 0..<32 {
            guard let d = devices[s], (d.get16(0x04) & 0x2) != 0 else { continue }
            for b in 0..<6 where d.barSize[b] != 0 {
                let base = d.barAddr(b)
                if base != 0 && pa >= base && pa - base < d.barSize[b] {
                    return (d, b, pa - base)
                }
            }
        }
        return nil
    }

    func windowRead(offset: UInt64, size: Int) -> UInt64 {
        guard let (d, bar, boff) = barLookup(pa: PcieBus.mmioBase + offset), let r = d.barRead else { return UInt64.max }
        return r(d, bar, boff, size)
    }

    func windowWrite(offset: UInt64, value: UInt64, size: Int) {
        guard let (d, bar, boff) = barLookup(pa: PcieBus.mmioBase + offset), let w = d.barWrite else { return }
        w(d, bar, boff, value, size)
    }
}

// MARK: - virtio トランスポート（PCI、モダンのみ）

struct Virtq {
    var size: UInt16 = 1024
    var enabled: UInt16 = 0
    var lastAvail: UInt16 = 0
    var desc: UInt64 = 0
    var avail: UInt64 = 0
    var used: UInt64 = 0
    var out = [Bool](repeating: false, count: 1024)
}

struct VirtqSeg {
    var addr: UInt64
    var len: UInt32
    var write: Bool   // デバイスが書く（ドライバが読む）
}

struct VirtqElem {
    var head: UInt16 = 0
    var segs: [VirtqSeg] = []
}

final class VirtioDevice {
    let pci = PciDevice()
    var features: UInt64 = 0
    var driverFeatures: UInt64 = 0
    var dfsel: UInt32 = 0
    var gfsel: UInt32 = 0
    var status: UInt8 = 0
    var isr: UInt8 = 0
    var configGen: UInt8 = 0
    var qsel: UInt16 = 0
    var nq = 0
    var queues: [Virtq] = []
    var config = [UInt8](repeating: 0, count: 256)
    var configLen = 0
    var notify: ((VirtioDevice, Int) -> Void)?
    var configWrite: ((VirtioDevice, UInt32, UInt64, Int) -> Void)?
    var onStatus: ((VirtioDevice) -> Void)?   // status 変化（リセット含む）の通知
    var physRead: (UInt64, Int) -> [UInt8]? = { _, _ in nil }
    var physWrite: (UInt64, [UInt8]) -> Void = { _, _ in }

    static let barIndex = 4
    static let commonOff: UInt64 = 0x0000
    static let isrOff: UInt64 = 0x1000
    static let deviceOff: UInt64 = 0x2000
    static let notifyOff: UInt64 = 0x3000
    static let notifyMult: UInt64 = 4

    init(deviceId: Int, classCode: UInt32, nq: Int, features: UInt64) {
        self.nq = nq
        self.features = features | (UInt64(1) << 32)   // VERSION_1
        pci.pciInit(vendor: 0x1AF4, device: UInt16(0x1040 + deviceId), classRev: (classCode << 8) | 1,
                    subVendor: 0x1AF4, subId: UInt16(deviceId))
        pci.opaque = self
        pci.barRead = { [weak self] _, bar, off, size in self?.barRead(bar: bar, off: off, size: size) ?? UInt64.max }
        pci.barWrite = { [weak self] _, bar, off, value, size in self?.barWrite(bar: bar, off: off, value: value, size: size) }
        pci.addBar(VirtioDevice.barIndex, size: 0x4000, is64: true)
        pci.config[0x06] |= 0x10   // capabilities list
        pci.config[0x34] = 0x40
        addCap(at: 0x40, next: 0x50, type: 1, off: UInt32(VirtioDevice.commonOff), len: 0x38)
        addCap(at: 0x50, next: 0x60, type: 3, off: UInt32(VirtioDevice.isrOff), len: 1)
        addCap(at: 0x60, next: 0x70, type: 4, off: UInt32(VirtioDevice.deviceOff), len: 0x100)
        addCap(at: 0x70, next: 0x00, type: 2, off: UInt32(VirtioDevice.notifyOff), len: UInt32(VirtioDevice.notifyMult * 4))
        reset()
    }

    private func addCap(at: Int, next: UInt8, type: UInt8, off: UInt32, len: UInt32) {
        let c = at
        pci.config[c + 0] = 0x09   // vendor-specific
        pci.config[c + 1] = next
        pci.config[c + 2] = type == 2 ? 20 : 16
        pci.config[c + 3] = type
        pci.config[c + 4] = UInt8(VirtioDevice.barIndex)
        for i in 0..<4 { pci.config[c + 8 + i] = UInt8((off >> UInt32(8 * i)) & 0xFF) }
        for i in 0..<4 { pci.config[c + 12 + i] = UInt8((len >> UInt32(8 * i)) & 0xFF) }
        if type == 2 {
            let mult = UInt32(VirtioDevice.notifyMult)
            for i in 0..<4 { pci.config[c + 16 + i] = UInt8((mult >> UInt32(8 * i)) & 0xFF) }
        }
    }

    func reset() {
        driverFeatures = 0
        dfsel = 0; gfsel = 0
        status = 0
        isr = 0
        qsel = 0
        queues = (0..<nq).map { _ in Virtq() }
        pci.setIntx(false)
    }

    func interrupt() {
        isr |= 1
        pci.setIntx(true)
    }

    // 注: デバイス固有 config は生成時に確定し実行中は変わらないため、
    // config_generation（0x15）は 0 のままが正しい（変更通知は発生しない）。

    // MARK: BAR（common / ISR / device config / notify）

    private func commonRead(_ off: UInt64) -> UInt64 {
        let q = qsel < nq ? queues[Int(qsel)] : nil
        switch off {
        case 0x00: return UInt64(dfsel)
        case 0x04: return dfsel < 2 ? UInt64(UInt32(truncatingIfNeeded: features >> (32 * UInt64(dfsel)))) : 0
        case 0x08: return UInt64(gfsel)
        case 0x0C: return gfsel < 2 ? UInt64(UInt32(truncatingIfNeeded: driverFeatures >> (32 * UInt64(gfsel)))) : 0
        case 0x10: return 0xFFFF   // config_msix_vector: MSI-X なし
        case 0x12: return UInt64(nq)
        case 0x14: return UInt64(status)
        case 0x15: return UInt64(configGen)
        case 0x16: return UInt64(qsel)
        case 0x18: return UInt64(q?.size ?? 0)
        case 0x1A: return 0xFFFF   // queue_msix_vector
        case 0x1C: return UInt64(q?.enabled ?? 0)
        case 0x1E: return UInt64(qsel)   // queue_notify_off = キュー番号
        case 0x20: return UInt64(UInt32(truncatingIfNeeded: q?.desc ?? 0))
        case 0x24: return UInt64(UInt32(truncatingIfNeeded: (q?.desc ?? 0) >> 32))
        case 0x28: return UInt64(UInt32(truncatingIfNeeded: q?.avail ?? 0))
        case 0x2C: return UInt64(UInt32(truncatingIfNeeded: (q?.avail ?? 0) >> 32))
        case 0x30: return UInt64(UInt32(truncatingIfNeeded: q?.used ?? 0))
        case 0x34: return UInt64(UInt32(truncatingIfNeeded: (q?.used ?? 0) >> 32))
        default: return 0
        }
    }

    private func set64(_ field: inout UInt64, off: UInt64, value: UInt64, size: Int) {
        if size == 8 { field = value }
        else if off & 4 != 0 { field = (field & 0xFFFF_FFFF) | (value << 32) }
        else { field = (field & ~UInt64(0xFFFF_FFFF)) | UInt64(UInt32(truncatingIfNeeded: value)) }
    }

    private func commonWrite(_ off: UInt64, value: UInt64, size: Int) {
        switch off {
        case 0x00: dfsel = UInt32(truncatingIfNeeded: value)
        case 0x08: gfsel = UInt32(truncatingIfNeeded: value)
        case 0x0C:
            if gfsel < 2 {
                let shift = 32 * UInt64(gfsel)
                let mask = UInt64(0xFFFF_FFFF) << shift
                driverFeatures = (driverFeatures & ~mask) | ((UInt64(UInt32(truncatingIfNeeded: value)) << shift) & features)
            }
        case 0x14:
            if UInt8(truncatingIfNeeded: value) == 0 {
                reset()
            } else {
                status = UInt8(truncatingIfNeeded: value)
            }
            onStatus?(self)
        case 0x16: qsel = UInt16(truncatingIfNeeded: value)
        case 0x18:
            guard qsel < nq else { break }
            let v = UInt16(truncatingIfNeeded: value)
            if v != 0 && v <= 1024 && (v & (v - 1)) == 0 { queues[Int(qsel)].size = v }
        case 0x1C:
            guard qsel < nq else { break }
            queues[Int(qsel)].enabled = UInt16(truncatingIfNeeded: value) & 1
        case 0x20, 0x24:
            guard qsel < nq else { break }
            set64(&queues[Int(qsel)].desc, off: off, value: value, size: size)
        case 0x28, 0x2C:
            guard qsel < nq else { break }
            set64(&queues[Int(qsel)].avail, off: off, value: value, size: size)
        case 0x30, 0x34:
            guard qsel < nq else { break }
            set64(&queues[Int(qsel)].used, off: off, value: value, size: size)
        default: break
        }
    }

    func barRead(bar: Int, off: UInt64, size: Int) -> UInt64 {
        guard bar == VirtioDevice.barIndex else { return UInt64.max }
        if off < VirtioDevice.isrOff { return commonRead(off) }
        if off < VirtioDevice.deviceOff {
            let v = isr
            isr = 0
            pci.setIntx(false)
            return UInt64(v)
        }
        if off < VirtioDevice.notifyOff {
            let o = Int(off - VirtioDevice.deviceOff)
            guard o < configLen else { return 0 }
            var r: UInt64 = 0
            let n = min(size, configLen - o)
            for i in 0..<n { r |= UInt64(config[o + i]) << UInt64(8 * i) }
            return r
        }
        return 0
    }

    func barWrite(bar: Int, off: UInt64, value: UInt64, size: Int) {
        guard bar == VirtioDevice.barIndex else { return }
        if off < VirtioDevice.isrOff {
            commonWrite(off, value: value, size: size)
        } else if off >= VirtioDevice.deviceOff && off < VirtioDevice.notifyOff {
            configWrite?(self, UInt32(off - VirtioDevice.deviceOff), value, size)
        } else if off >= VirtioDevice.notifyOff {
            let q = Int((off - VirtioDevice.notifyOff) / VirtioDevice.notifyMult)
            if q < nq && queues[q].enabled != 0 && (status & 4) != 0 {
                notify?(self, q)   // DRIVER_OK のときだけ
            }
        }
    }

    // MARK: virtqueue

    /// 利用可能になった要素を 1 つ取る。なければ nil、壊れていれば空要素（head のみ）を返す。
    func virtqPop(_ qi: Int) -> VirtqElem? {
        var q = queues[qi]
        guard let hdr = physRead(q.avail, 4 + 2 * Int(q.size)) else { return nil }
        let idx = UInt16(hdr[2]) | UInt16(hdr[3]) << 8
        if q.lastAvail == idx { return nil }
        let headSlot = 2 + Int(q.lastAvail % q.size) * 2
        let head = UInt16(hdr[headSlot]) | UInt16(hdr[headSlot + 1]) << 8
        if head >= q.size { return nil }   // まだ書かれていない: 次回に回す（Henge 準拠）
        q.lastAvail &+= 1
        q.out[Int(head)] = true
        queues[qi] = q
        var e = VirtqElem(head: head)
        var table = q.desc
        var count = UInt32(q.size)
        var i = UInt32(head)
        var steps = 0
        while steps < 128 {
            steps += 1
            guard i < count, let d = physRead(table &+ 16 &* UInt64(i), 16) else { return e }
            let addr = (0..<8).reduce(UInt64(0)) { $0 | UInt64(d[$1]) << UInt64(8 * $1) }
            let len = (0..<4).reduce(UInt32(0)) { $0 | UInt32(d[8 + $1]) << UInt32(8 * $1) }
            let flags = UInt16(d[12]) | UInt16(d[13]) << 8
            let next = UInt16(d[14]) | UInt16(d[15]) << 8
            if flags & 4 != 0 {   // INDIRECT
                table = addr
                count = len / 16
                i = 0
                continue
            }
            e.segs.append(VirtqSeg(addr: addr, len: len, write: flags & 2 != 0))
            if flags & 1 == 0 { return e }
            i = UInt32(next)
        }
        return e
    }

    func virtqPush(_ qi: Int, _ e: VirtqElem, written: UInt32) {
        var q = queues[qi]
        guard e.head < q.size && q.out[Int(e.head)] else { return }
        q.out[Int(e.head)] = false
        queues[qi] = q
        let usedBytes = 4 + 8 * Int(q.size)
        guard var used = physRead(q.used, usedBytes) else { return }
        var idx = UInt16(used[2]) | UInt16(used[3]) << 8
        let slot = 4 + 8 * Int(idx % q.size)
        for i in 0..<4 { used[slot + i] = UInt8((UInt32(e.head) >> UInt32(8 * i)) & 0xFF) }
        for i in 0..<4 { used[slot + 4 + i] = UInt8((written >> UInt32(8 * i)) & 0xFF) }
        idx &+= 1
        used[2] = UInt8(idx & 0xFF); used[3] = UInt8((idx >> 8) & 0xFF)
        physWrite(q.used, used)
    }

    /// 要素のバッファとコピーする（writable=true: デバイス書き込み側へ書く / false: 読み取り側から読む）。
    /// off は対象方向のストリーム先頭からのスキップ量。
    private func virtqCopy(_ e: VirtqElem, writable: Bool, off: UInt32, buf: inout [UInt8], writing: Bool) -> Int {
        var done = 0
        var skip = off
        for g in e.segs {
            if done >= buf.count { break }
            if g.write != writable { continue }
            if skip >= g.len { skip -= g.len; continue }
            let n = min(Int(g.len - skip), buf.count - done)
            if writing {
                physWrite(g.addr &+ UInt64(skip), [UInt8](buf[done..<done + n]))
            } else if let bytes = physRead(g.addr &+ UInt64(skip), n) {
                buf.replaceSubrange(done..<done + n, with: bytes)
            } else { break }
            done += n
            skip = 0
        }
        return done
    }

    func virtqRead(_ e: VirtqElem, off: UInt32, count: Int) -> [UInt8] {
        // ゲスト申告の長さをそのまま確保すると巨大アロケーションで落ちるため上限を設ける
        let count = min(max(count, 0), 64 << 20)
        var buf = [UInt8](repeating: 0, count: count)
        _ = virtqCopy(e, writable: false, off: off, buf: &buf, writing: false)
        return buf
    }

    @discardableResult
    func virtqWrite(_ e: VirtqElem, off: UInt32, bytes: [UInt8]) -> Int {
        var buf = bytes
        return virtqCopy(e, writable: true, off: off, buf: &buf, writing: true)
    }

    func virtqWritable(_ e: VirtqElem) -> Int {
        e.segs.filter { $0.write }.reduce(0) { $0 + Int($1.len) }
    }
    func virtqReadable(_ e: VirtqElem) -> Int {
        e.segs.filter { !$0.write }.reduce(0) { $0 + Int($1.len) }
    }
}

// MARK: - virtio-blk（Apple バリアント）

final class VirtioBlk {
    let vio: VirtioDevice
    let disk: BdifDisk

    // features: SEG_MAX(2) | BLK_SIZE(6) | FLUSH(9)
    init(disk: BdifDisk, appleVariant: UInt32) {
        self.disk = disk
        vio = VirtioDevice(deviceId: 2, classCode: 0x010000, nq: 1,
                           features: (1 << 2) | (1 << 6) | (1 << 9))
        vio.notify = { [weak self] v, q in self?.handleNotify(v, q) }
        // デバイス固有 config（96 バイト）
        var cfg = [UInt8](repeating: 0, count: 96)
        let capacity = UInt64(disk.size / 512)
        for i in 0..<8 { cfg[0 + i] = UInt8((capacity >> UInt64(8 * i)) & 0xFF) }
        let segMax: UInt32 = 8   // Henge の実績値（Apple ドライバの ENOMEM 回避）
        for i in 0..<4 { cfg[12 + i] = UInt8((segMax >> UInt32(8 * i)) & 0xFF) }
        let blkSize: UInt32 = 512
        for i in 0..<4 { cfg[20 + i] = UInt8((blkSize >> UInt32(8 * i)) & 0xFF) }
        cfg[34] = 1; cfg[35] = 0   // num_queues = 1
        for i in 0..<4 { cfg[60 + i] = UInt8((appleVariant >> UInt32(8 * i)) & 0xFF) }
        vio.config = cfg
        vio.configLen = 96
        // Apple の PCI ID（0x106B:0x1A00）
        vio.pci.put16(0x00, 0x106B)
        vio.pci.put16(0x02, 0x1A00)
        // ベンダデータ capability（cfg_type 9）: 先頭バイト bit0 = 非インライン暗号化
        vio.pci.config[0x71] = 0x88   // notify cap の next をここへつなぐ
        let cap = 0x88
        vio.pci.config[cap + 0] = 0x09
        vio.pci.config[cap + 1] = 0x00
        vio.pci.config[cap + 2] = 6 + 8
        vio.pci.config[cap + 3] = 9
        vio.pci.config[cap + 4] = 0x6B; vio.pci.config[cap + 5] = 0x10   // vendor 0x106B
        vio.pci.config[cap + 6] = 1   // not inline-encrypted
    }

    private func handleNotify(_ v: VirtioDevice, _ q: Int) {
        var any = false
        while let e = v.virtqPop(q) {
            let written = handle(v, e)
            v.virtqPush(q, e, written: written)
            any = true
        }
        if any { v.interrupt() }
    }

    /// 戻り値は used に書く長さ（データ長＋ステータス 1 バイト）
    private func handle(_ v: VirtioDevice, _ e: VirtqElem) -> UInt32 {
        let wlen = v.virtqWritable(e)
        guard wlen >= 1 else { return 0 }
        let dataLen = wlen - 1
        // ヘッダ（16 バイト）が読めない壊れたチェーンは IOERR で完了する（Henge 準拠）
        guard v.virtqReadable(e) >= 16 else {
            v.virtqWrite(e, off: UInt32(dataLen), bytes: [1])
            return 1
        }
        let hdr = v.virtqRead(e, off: 0, count: 16)
        let type = (0..<4).reduce(UInt32(0)) { $0 | UInt32(hdr[$1]) << UInt32(8 * $1) }
        let sector = (0..<8).reduce(UInt64(0)) { $0 | UInt64(hdr[8 + $1]) << UInt64(8 * $1) }
        // セクタ→バイト変換のオーバーフローを避けるため UInt64 のまま範囲を確認する
        let byteOffset = sector &* 512
        let inRange = sector <= UInt64(disk.size) / 512 && byteOffset + UInt64(dataLen) <= UInt64(disk.size)
        var status: UInt8 = 0   // OK
        var written = 0
        switch type {
        case 0:   // T_IN（読み）
            if inRange, let bytes = disk.read(offset: Int(byteOffset), count: dataLen) {
                written = v.virtqWrite(e, off: 0, bytes: bytes)
            } else { status = 1 }
        case 1:   // T_OUT（書き）
            let rlen = v.virtqReadable(e)
            if inRange && rlen >= 16 {
                let bytes = v.virtqRead(e, off: 16, count: rlen - 16)
                if !disk.write(offset: Int(byteOffset), bytes: bytes) { status = 1 }
            } else { status = 1 }
        case 4:   // T_FLUSH
            break
        case 8:   // T_GET_ID（ID 領域は 20 バイト、残りは 0 埋め）
            var id = [UInt8]("retasuvm-disk".utf8)
            if id.count < 20 { id += [UInt8](repeating: 0, count: 20 - id.count) }
            let n = min(dataLen, id.count)
            written = v.virtqWrite(e, off: 0, bytes: [UInt8](id.prefix(n)))
        case 0x10000:   // T_APPLE_BARRIER: 順序実行なので no-op
            break
        default:
            status = 2   // UNSUPP
        }
        if status != 0 { written = 0 }
        v.virtqWrite(e, off: UInt32(dataLen), bytes: [status])
        return UInt32(written + 1)
    }
}

// MARK: - virtio-usb フロントエンド（bdif と同じメッセージリングを共有）

final class VirtioUsbDevice {
    let vio: VirtioDevice
    var pciOn = false
    weak var cpu: ARM64CPU?

    init(cpu: ARM64CPU) {
        self.cpu = cpu
        vio = VirtioDevice(deviceId: 0, classCode: 0x0C03FE, nq: 2, features: 0)
        // Apple の PCI ID（ベンダ・デバイス・サブシステム）
        vio.pci.put16(0x00, 0x106B)
        vio.pci.put16(0x02, 0x1A01)
        vio.pci.put16(0x2C, 0x106B)
        vio.pci.put16(0x2E, 0x1A01)
        vio.notify = { [weak self] _, q in
            guard let self else { return }
            if q == 1 { self.drainResponses() } else { self.deliverRequests() }
        }
        vio.onStatus = { [weak self] _ in self?.trackStatus() }
    }

    /// DRIVER_OK を見てバス接続状態を追随する（Henge track_status 相当）
    func trackStatus() {
        let on = (vio.status & 4) != 0
        if on == pciOn { return }
        pciOn = on
        if on { cpu?.usbRomOnSet(false) }
        cpu?.vusbSetOnlineFromDevice(on)
    }

    func poll() {
        trackStatus()
        guard pciOn else { return }
        if vio.queues[1].enabled != 0 { drainResponses() }
        if vio.queues[0].enabled != 0 { deliverRequests() }
    }

    private func deliverRequests() {
        guard let cpu else { return }
        var any = false
        while let m = cpu.vusbPeekRequest() {
            guard let e = vio.virtqPop(0) else { break }
            _ = cpu.vusbTakeRequest()
            let payload = m.data ?? []
            var msg = [UInt8]()
            msg += [UInt8(m.len & 0xFF), UInt8((m.len >> 8) & 0xFF), UInt8((m.len >> 16) & 0xFF), UInt8((m.len >> 24) & 0xFF), m.ep, m.type]
            msg += payload
            let n = vio.virtqWrite(e, off: 0, bytes: msg)
            vio.virtqPush(0, e, written: UInt32(n))
            any = true
        }
        if any { vio.interrupt() }
    }

    private func drainResponses() {
        guard let cpu else { return }
        var any = false
        while let e = vio.virtqPop(1) {
            let total = vio.virtqReadable(e)
            if total >= 2 {
                let bytes = vio.virtqRead(e, off: 0, count: total)
                cpu.vusbPutResponse(type: bytes[0], ep: bytes[1],
                                    data: bytes.count > 2 ? [UInt8](bytes[2...]) : nil)
            }
            vio.virtqPush(1, e, written: 0)
            any = true
        }
        if any { vio.interrupt() }
    }
}
