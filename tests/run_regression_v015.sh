#!/bin/bash
# v0.15.0 全回帰テスト: ハーネス再ビルド + バッテリー実行
export PATH=~/workspace/swift-toolchain/swift-5.10.1-RELEASE-ubuntu24.04/usr/bin:$PATH
cd ~/workspace/retasuvm/tests || exit 1
R=../repo/retasuVM.swiftpm
E=$R/Engine
D=../dist

echo "=== BUILDS ==="
swiftc -O -o h_guest $E/*.swift $R/Models/VirtualMachine.swift guest/main.swift 2>&1 | grep -E "error" | head -3
swiftc -O -o h_codable $E/*.swift $R/Models/VirtualMachine.swift codable/main.swift 2>&1 | grep -E "error" | head -3
swiftc -O -o h_persist $E/*.swift $R/Models/VirtualMachine.swift persist/main.swift 2>&1 | grep -E "error" | head -3
swiftc -O -o h_samples $E/*.swift $R/Models/VirtualMachine.swift samples/main.swift 2>&1 | grep -E "error" | head -3
swiftc -O -o h_arm64 $E/ARM64CPU.swift $E/ARM64NVMe.swift arm64/main.swift 2>&1 | grep -E "error" | head -3
swiftc -O -o h_arm64demo $E/ARM64CPU.swift $E/ARM64NVMe.swift $E/ARM64Assembler.swift $E/ARM64DemoOS.swift arm64demo/main.swift 2>&1 | grep -E "error" | head -3
echo "BUILDS_DONE"

check() {
  local name="$1" expect="$2"; shift 2
  local out
  out=$("$@" 2>&1)
  if echo "$out" | grep -qF "$expect"; then
    echo "PASS $name"
  else
    echo "FAIL $name (expected: $expect)"
    echo "$out" | tail -5
  fi
}

echo "=== BATTERY ==="
check mb_kernel "kernel ready - halting" ./h_mb $D/retasuVM-sample-kernel.elf
check mb_ring "ALL RING OK" ./h_mb $D/retasuVM-sample-ring.elf
check mb_lm "ALL LM DONE" ./h_mb $D/retasuVM-sample-lm.elf
check mb_devices "ALL DEVICES DONE" ./h_mb $D/retasuVM-sample-devices.elf
check mb_dma "ALL DMA OK" ./h_mb $D/retasuVM-sample-dma.elf sectors
check mb_task "ALL CPU OK" ./h_mb $D/retasuVM-sample-task.elf
check mb_fpu "ALL FPU/SSE OK" ./h_mb $D/retasuVM-sample-fpu.elf
check mb_cpux "ALL CPUX OK" ./h_mb $D/retasuVM-sample-cpux.elf vga
check mb_cpux_vga "VGA DRAWN" ./h_mb $D/retasuVM-sample-cpux.elf vga
check mb_osx "ALL OSXSUB OK" ./h_mb $D/retasuVM-sample-osx.elf sectors
check sess_uefi "UEFI APP BARE METAL OK" ./h_sess $D/retasuVM-sample-uefi.efi
check sess_uefi2 "EFI2 DONE" ./h_sess $D/retasuVM-sample-uefi2.efi
check sess_uefi3 "UEFI3 DONE" ./h_sess $D/retasuVM-sample-uefi3.efi
check sess_lfn "LFN DONE" ./h_sess $D/retasuVM-sample-lfn.efi
check sess_uefi4 "UEFI4 DONE" ./h_sess $D/retasuVM-sample-uefi4.efi "800:ZQ"
check sess_uefi5 "UEFI5 DONE" ./h_sess $D/retasuVM-sample-uefi5.efi
check sess_bios "Hello from sector 2" ./h_sess $D/retasuVM-sample-x86.iso
check guest_riscv "fib(46) = 1836311903" ./h_guest riscv 'fib 46\nhalt'
check guest_arm "12! = 479001600" ./h_guest arm 'fact\nhalt'
check samples "ALL SAMPLES OK" ./h_samples
check arm64 "ALL ARM64 OK" ./h_arm64 arm64kernel/kernel_arm64.elf
check arm64demo "479001600" ./h_arm64demo 'help\nfact\necho hi\nquit'
check mac "ALL MACBOOT OK" ./h_mac mackernel/kernel_mac.elf

OUT=$(./h_codable 2>&1)
COUNT=$(echo "$OUT" | grep -c "OK")
if [ "$COUNT" = "4" ]; then echo "PASS codable"; else echo "FAIL codable (ok lines=$COUNT)"; echo "$OUT" | tail -5; fi

OUT=$(./h_persist uefi3/persist_set.efi uefi3/persist_get.efi 2>&1)
if echo "$OUT" | grep -qF "PERSIST OK"; then echo "PASS persist"; else echo "FAIL persist"; echo "$OUT" | tail -5; fi

echo "=== REGRESSION_DONE ==="
