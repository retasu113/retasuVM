# retasuVM

retasuVM は、iPhone と iPad で仮想マシンを管理するための SwiftUI アプリです。
Apple Human Interface Guidelines（HIG）に沿って設計し、Swift Playgrounds でそのまま開けるプロジェクト形式（`.swiftpm`）で配布します。

> **現在の実行エンジンについて**: v0.12.0 の実行エンジンは、すべて自作のソフトウェア CPU エミュレータ 3 種類です。RISC-V（RV32IM）、x86（リアルモード + 32 ビット プロテクトモード + 64 ビット ロングモード + x87 FPU / MMX / SSE / SSE2 / SSE3 / SSSE3 / SSE4.1 + 自作 BIOS / 最小 UEFI + 周辺デバイス群）、ARM（ARMv7-A サブセット）を VM ごとに選べます。x86 は El Torito 対応 ISO から BIOS ブートできるほか、Multiboot 対応カーネル（ELF32）をプロテクトモードで直接起動でき、ロングモードへの移行、APIC 割り込み、ACPI テーブルの読み取り、UEFI アプリケーション（.efi）の実行が可能です。UEFI はプロトコルデータベース、Loaded Image プロトコル、LoadImage / StartImage / Exit（デバイスパス経由の読み込み対応）、イベント / タイマと通知関数の呼び出し、Driver Binding プロトコルによるドライバ接続、ConIn（キー入力）、GOP（3 モードのフレームバッファ。アプリの画面表示に描画）、本物のメモリアロケータ、Secure Boot（イメージハッシュ方式）、SetVirtualAddressMap、Block I/O、Simple File System（FAT12 / 16 / 32 の読み書き、ロングファイル名の書き込み対応）、永続化される変数サービスまで備えましたが、証明書方式の Secure Boot や TPM などは未提供のため、Windows や現在の Linux のような一般の OS はまだ実行できません。

## 主な機能

- 仮想マシンの一覧表示・検索（名前でフィルタ）
- 仮想マシンの作成・編集（名前、ゲスト OS、CPU、メモリ、ディスク、ネットワーク、共有フォルダ）
- 起動 / 一時停止 / 再開 / 再起動 / 停止 / 強制停止（状態に応じた操作のみ表示）
- 状態表示は色だけに頼らず、シンボルとラベルで表示（実行中・停止中・一時停止中・エラー）
- 破壊的操作（削除・強制停止）には確認ダイアログを表示
- RISC-V エミュレータ上で動く 3 つのゲスト OS イメージ（VM ごとに選択可能）
  - retasuOS: 対話型モニタ（help / echo / fib / about / ver / clear / halt）
  - PlayOS: 数当てゲームとサイコロ（guess / dice / help / quit）
  - CalcOS: スタック式（RPN）計算機（+ - * / % / dup / drop / swap / p など）
- ISO ファイルからの起動（ISO 9660 を解析し BOOT.BIN を実行。ISO 全体はディスクとしてゲストから読み取り可能）
- x86 エミュレータ（リアルモード + 32 ビット プロテクトモード + 64 ビット ロングモード CPU + 自作 BIOS / 最小 UEFI）
  - El Torito 対応 ISO から BIOS ブート（フロッピー / ハードディスク エミュレーション）
  - ブートセクタ付き raw イメージ（.img）からもブート可能
  - BIOS コール対応: INT 10h（画面）/ INT 13h（ディスク、CHS・LBA）/ INT 16h（キーボード）/ INT 12h / INT 1Ah / INT 15h（E820 メモリマップ含む）
  - 32 ビット プロテクトモード対応（GDT / LDT、IDT 割り込み・例外配送、ページング、CPUID）
  - 64 ビット ロングモード対応（REX プリフィクス、4 階層ページング、EFER、IRETQ、RIP 相対アドレッシング、FS/GS ベース MSR、CR8 = LAPIC TPR）
  - Multiboot ブートローダ内蔵: Multiboot 対応 ELF32 カーネルを直接起動（ISO 内の KERNEL.ELF も自動検出）
  - UEFI ファームウェア: PE32+（x86-64）アプリケーション（.efi）をロングモードで起動。コンソール入出力（ConOut / ConIn）と基本ブートサービス（メモリマップ取得、メモリ確保、ExitBootServices など）に加え、プロトコルデータベース（Install / Handle / Locate / Open）、イベント通知関数の呼び出し、Driver Binding によるドライバ接続、Block I/O、Simple File System（自作 FAT12 / 16 / 32 の読み書き）、変数サービス（Get / Set / GetNextVariableName）、本物のメモリアロケータ（FreePages / FreePool / アドレス指定確保）、Secure Boot（イメージハッシュ方式、PK / db / dbx）、SetVirtualAddressMap（仮想アドレス経由のランタイム呼び出し）を提供し、SystemTable の ConfigurationTable から ACPI RSDP を参照可能
  - 特権リング対応: リング 0〜3（CPL 管理、TSS による割り込みスタック切替、ページの U/S 検査）、SYSCALL / SYSRET（STAR / LSTAR / SFMASK MSR）
  - 浮動小数点・SIMD 対応: x87 FPU（全メモリ形式・超越関数・制御ワードの丸め制御、FNSAVE / FRSTOR、CR0.TS の #NM）と MMX、SSE / SSE2 / SSE3 / SSSE3 / SSE4.1 サブセット（浮動小数点 / 整数演算、変換、FXSAVE / FXRSTOR、XSAVE / XRSTOR）、POPCNT / MOVBE / RDTSC・RDTSCP / CMPXCHG8B・16B
  - ACPI テーブル生成: RSDP / XSDT / RSDT / FADT / DSDT / MADT（チェックサム付き）を BIOS 領域に配置
  - 周辺デバイス再現: 割り込みコントローラ（8259A PIC ×2、LAPIC タイマ、IOAPIC）、タイマ（8254 PIT）、キーボードコントローラ（8042、スキャンコード + IRQ1）、PCI ホストブリッジ（ホスト / ISA / IDE / VGA の 4 デバイスを列挙可能）、IDE（ATA）ディスク（PIO + バスマスタ DMA、BIOS とイメージ共有）、RTC / CMOS、シリアル（16550 相当、割り込み対応）
  - HLT での割り込み待ち（アイドル）と、タイマ割り込みによる復帰に対応
  - シリアルポート（COM1）とポート 0xE9 デバッグコンソールをコンソールに接続
- ARM エミュレータ（ARMv7-A、A32 命令サブセット + 自作アセンブラ）
  - デモゲスト「ArmDemoOS」（help / fact / echo / quit）
- 対話型コンソール画面（コマンド入力・イメージ連動のクイックコマンド・リアルタイム出力）と画面表示（GOP フレームバッファ / VGA テキスト画面 / VGA モード 13h をコンソールと切り替えて表示。変更通知で即時更新）
- 設定は端末内に自動保存され、再起動後も保持
- iPad ではサイドバー付きスプリットビュー、iPhone ではタブバー＋スタック遷移

## 対応プラットフォーム

- iOS 17 以降 / iPadOS 17 以降
- iPhone / iPad（縦横画面対応）
- Swift Playgrounds 4 以降（iPad / iPhone / Mac）または Xcode 15 以降

## Swift Playgrounds での導入方法

### GitHub Releases から ZIP を取得する方法

1. このリポジトリの [Releases](../../releases) ページを開きます。
2. 使いたいバージョン（例: `v0.1.0`）の Assets から、次の 2 つをダウンロードします。
   - `retasuVM-vX.X.X-SwiftPlaygrounds.zip`（プロジェクト一式）
   - `SHA256SUMS.txt`（ZIP の SHA-256 ハッシュ。改ざん検知用）
3. 必要に応じて、ダウンロードした ZIP の SHA-256 が `SHA256SUMS.txt` の値と一致するか確認してください。

### ZIP を Swift Playgrounds で開く方法

1. ダウンロードした ZIP を「ファイル」アプリでタップして展開します。
2. 展開された `retasuVM.swiftpm` をタップすると、Swift Playgrounds で開きます。
   - 開けない場合は、Swift Playgrounds を起動し、「開く」から `retasuVM.swiftpm` を選んでください。
3. Swift Playgrounds 上部の実行ボタン（▶）を押すとアプリが起動します。

詳しいビルド・検証手順は [BUILD.md](BUILD.md) を参照してください。

## ISO ファイルから起動する

### RISC-V（BOOT.BIN 形式）

1. Release から `retasuVM-sample.iso`（試作用サンプル）をダウンロードします。
2. アプリで VM を作成（または編集）し、CPU アーキテクチャを「RISC-V」、起動方法を「ISO ファイル」にして、ダウンロードした .iso を選びます。
3. VM を起動すると、ISO 内のゲスト OS「IsoDemoOS」がブートします。コンソールで `info` と入力すると、ディスクの容量やボリュームラベルが表示されます。

自作 ISO の規約: ISO 9660 のルート直下に `BOOT.BIN`（RISC-V RV32IM フラットバイナリ、最大 1 MiB）を置きます。ISO 全体はディスクとして装着され、ゲストはシステムコール（a7=20/21/22）でセクタ読み取りできます。詳細はサンプル ISO 内の README.TXT と `Engine/RISCVCPU.swift` を参照してください。

### x86（BIOS / El Torito 形式）

1. Release から `retasuVM-sample-x86.iso`（試作用サンプル）をダウンロードします。
2. アプリで VM を作成（または編集）し、CPU アーキテクチャを「x86」にして、ダウンロードした .iso を選びます。
3. VM を起動すると、内蔵 BIOS が El Torito ブートイメージ（1.44 MB フロッピー）からブートセクタを読み込んで実行します。デモはブートドライブ番号の表示、INT 13h でのセクタ読み取り、キーエコー（ESC で停止）を行います。

x86 で起動できるのは、El Torito 対応 ISO（フロッピー / ハードディスク エミュレーション、エミュレーションなし）と、ブートセクタ（55 AA）付きの raw イメージです。ゲストは 16 ビット リアルモードで動作し、BIOS コール（INT 10h / 13h / 16h など）とシリアルポート（COM1）が使えます。ブートセクタから GDT を設定して 32 ビット プロテクトモードへ移行する OS も動作します（ページング、IDT 割り込み対応）。さらに 4 階層ページングと EFER を設定すれば 64 ビット ロングモードへ移行できます（動作確認用カーネル `retasuVM-sample-lm.elf` が Release にあります。起動すると ACPI テーブルの走査、ロングモード移行、LAPIC タイマ、IOAPIC 経由キーボード割り込みを順に確認します）。

### x86（Multiboot カーネル）

1. Release から `retasuVM-sample-kernel.elf`（試作用サンプル）をダウンロードします。
2. アプリで VM を作成（または編集）し、CPU アーキテクチャを「x86」にして、ダウンロードした .elf を選びます。
3. VM を起動すると、内蔵 Multiboot ローダがカーネルを読み込み、プロテクトモードで起動します。サンプルカーネルはメモリ情報を表示し、自らページングを有効化して停止します。

自作カーネルの条件: Multiboot（バージョン 1）ヘッダを持つ ELF32（i386）カーネル。ISO のルートに `KERNEL.ELF` という名前で置いた場合も自動で検出します。エントリ時点の状態は Multiboot 仕様どおり（プロテクトモード、フラットセグメント、EAX = 0x2BADB002、EBX = 情報構造体）です。

Multiboot 起動時は IDE に 16 MiB の RAM ディスクが接続されます（内容は VM の停止で消えます）。PIC / PIT / キーボード / PCI / IDE / RTC などのデバイスが使えます。動作をまとめて確認できる試作用カーネル `retasuVM-sample-devices.elf` も Release にあります。起動してコンソール入力で「A」と送ると、TIMER / KBD / PCI / IDE / RTC の確認結果が順に表示されます。

### x86（UEFI アプリケーション）

1. Release から `retasuVM-sample-uefi.efi`（試作用サンプル）をダウンロードします。
2. アプリで VM を作成（または編集）し、CPU アーキテクチャを「x86」にして、ダウンロードした .efi を選びます。
3. VM を起動すると、最小 UEFI ファームウェアが PE32+ イメージを読み込み、ロングモードでエントリポイントを呼びます（RCX = ImageHandle、RDX = SystemTable）。サンプルは ConOut へ挨拶を表示し、GetMemoryMap と ExitBootServices を呼んだあと、シリアルポートへ直接出力して停止します。

自作 UEFI アプリの条件: x86-64 の PE32+ イメージ（サブシステム: EFI アプリケーション / ブートサービスドライバ / ランタイムドライバ）。ImageBase は 16 MiB の RAM 内に収まる必要があります。使えるサービスは ConOut（OutputString など）と ConIn（ReadKeyStroke / WaitForEvent。アプリのコンソール入力がキーとして届きます）、ブートサービス（AllocatePages / AllocatePool / GetMemoryMap / ExitBootServices / Stall / CopyMem / SetMem / CalculateCrc32 / LoadImage / StartImage / Exit / UnloadImage / CreateEvent / SetTimer / WaitForEvent / CheckEvent など）、プロトコル関連サービス（InstallProtocolInterface / HandleProtocol / OpenProtocol / LocateProtocol / LocateHandle / LocateHandleBuffer / LocateDevicePath など）、イベント通知関数（SignalEvent / タイマ / プロトコルインストール / ExitBootServices などのイベントグループで呼び出されます）、ConnectController / DisconnectController（Driver Binding プロトコルの Supported / Start / Stop を呼びます）、LoadImage のデバイスパス経由の読み込み（FilePath ノード → Simple File System 上のファイル）、Loaded Image プロトコル、GOP（Graphics Output、640×400 フレームバッファ + Blt）、Block I/O プロトコル、Simple File System プロトコル（FAT ボリュームの読み書き、ロングファイル名対応。ディスク未接続時は RAM 上の FAT12 フロッピーが対象）、変数サービス（GetVariable / SetVariable / GetNextVariableName / QueryVariableInfo。変数は VM の構成に保存され、次回起動時に引き継がれます）、ランタイムサービス（GetTime / GetVariable 群 / ResetSystem など）です。ExitBootServices の後はブートサービスが無効化されます。一方で Secure Boot などは未提供のため、Windows Boot Manager や GRUB のような本格的なブートローダの起動はまだ保証できません。GOP のフレームバッファはアプリの画面表示に描画されます。

## 現在の開発状況

- v0.12.0: 残りの不足機能を実装した。x86 に MMX、SSE3 / SSSE3 / SSE4.1、POPCNT / MOVBE / RDTSC・RDTSCP / CMPXCHG8B・16B、XSAVE / XRSTOR、CR0.TS の #NM、FNSAVE / FRSTOR を追加。UEFI に本物のメモリアロケータ（FreePages / FreePool / アドレス指定確保 / UnloadImage 回収）、Secure Boot（イメージハッシュ方式、SetupMode / PK / db / dbx）、GOP の追加モード（800×600 / 1024×768）、CreateEventEx のイベントグループ、SetVirtualAddressMap（仮想アドレス経由のランタイム呼び出し）を追加。VGA モード 13h（DAC パレット付き）の描画、アプリ画面の変更通知、アプリアイコンにも対応。テストで見つかった実バグ（CLTS、SSSE3 水平演算、DPPS / DPPD マスク、80 ビット拡張精度の読み込みほか）も修正。新規統合テスト（CPU 拡張カーネル、UEFI5）と全回帰テストで検証済み。
- v0.11.0: 残りの不足機能を実装した。x86 に x87 FPU（全形式・超越関数）と SSE / SSE2 サブセット（FXSAVE / FXRSTOR 含む）を追加し、CPUID で申告するようになった。UEFI に ConIn（キー入力プロトコル）、イベント通知関数（NotifyFunction）の実際の呼び出し、ConnectController / DisconnectController での Driver Binding（Supported / Start / Stop）、LoadImage のデバイスパス経由の読み込みを追加。アプリのコンソールに画面表示を追加し、GOP フレームバッファと VGA テキスト画面を描画できるようになった。あわせてセッションの実行チャンクを広げ、スピン待ちするゲストの実行速度を大幅に改善した。新規統合テスト（FPU / SSE 検証カーネル、UEFI4）と全回帰テストで検証済み。
- v0.10.0: 残りの不足機能を実装した。x86 に SWAPGS と TSS ハードウェアタスクスイッチを追加。UEFI に Loaded Image プロトコル、LoadImage / StartImage / Exit / UnloadImage、GOP（フレームバッファ + Blt）、イベント / タイマ、残りのブート / ランタイムサービス、変数の永続化、ExitBootServices 後のブートサービス無効化を追加。FAT はロングファイル名の書き込みに対応。あわせて全 Swift ファイル（36 ファイル）を監査し、ページ書き込み保護の欠落や IDIV のトラップ、PE の Subsystem フィールドの読み違い（通常のリンカで作った .efi を UEFI アプリと認識できない問題）など、確定バグをすべて修正した。新規統合テスト（UEFI3 / 永続化 / LFN / タスクスイッチ・SWAPGS）と全回帰テストで検証済み。
- v0.9.0: x86 に特権リング（リング 3、TSS スタック切替、U/S 検査）と SYSCALL / SYSRET、IDE バスマスタ DMA を追加。UEFI にプロトコルデータベース、Block I/O、Simple File System（FAT12 / 16 / 32 読み書き）、変数サービスを追加。リング検証カーネル、DMA 検証カーネル、UEFI 統合テストアプリと全回帰テストで検証済み。
- v0.8.0: x86 に 64 ビット ロングモード（REX / 4 階層ページング / EFER）、LAPIC / IOAPIC、ACPI テーブル（RSDP〜MADT）、最小 UEFI ファームウェア（PE32+ ローダ + ConOut + 基本ブートサービス）を追加。ロングモード検証カーネルと UEFI サンプルアプリで実行テストを実施済み。
- v0.7.0: x86 に PC 周辺デバイス（PIC / PIT / キーボード / PCI / IDE / RTC / シリアル）を追加。割り込みで動く OS らしいカーネルが動作するようになった。デバイス検証カーネルと全エンジンの実行テストを実施済み。
- v0.6.0: x86 に 32 ビット プロテクトモード（GDT / IDT / ページング）と Multiboot ブートローダを追加。Multiboot 対応カーネルが起動できるようになった。サンプルカーネルと、全エンジンの実行テストを実施済み。
- v0.5.0: x86（リアルモード CPU + 自作 BIOS + El Torito ブート）と ARM（ARMv7-A サブセット + 自作アセンブラ + ArmDemoOS）の 2 エンジンを追加。アーキテクチャは VM ごとに選択可能。全 Swift ファイルの文法チェックと、3 エンジンすべての実行テストを実施済み。
- v0.4.0: ISO 9660 イメージからの起動に対応（BOOT.BIN 形式）。サンプル ISO と IsoDemoOS を同梱。全 Swift ファイルの文法チェックと、ISO ブートを含む実行テストを実施済み。
- v0.3.0: ゲストイメージを 3 種類に拡充（retasuOS / PlayOS / CalcOS）、CPU に M 拡張（乗除算）と乱数を追加。
- v0.2.0: RISC-V RV32I エミュレータとゲスト OS「retasuOS」を実装。
- v0.1.0: 初期リリース。HIG 準拠の管理 UI とシミュレーションエンジンを実装。
- 変更履歴は [CHANGELOG.md](CHANGELOG.md) を参照してください。
- 開発の必須要件（HIG 準拠、GitHub Releases、Swift Playgrounds ZIP 配布など）は [REQUIREMENTS.md](REQUIREMENTS.md) に定義しています。

## 既知の制約

- 実行できるゲストは、同梱イメージ（RISC-V 3 種 + ArmDemoOS）、retasuVM 形式の ISO（BOOT.BIN 入り）、x86 のリアルモード / プロテクトモード / ロングモード ブートプログラム（El Torito ISO / raw イメージ）、Multiboot 対応カーネル（ELF32）、最小 UEFI で動く PE32+ アプリケーション（.efi）です。一般の OS（Windows / 現在の Linux など）や、そのインストール ISO は実行できません（証明書方式の Secure Boot や TPM などが未提供のため）。
- x86 の特権リング、TSS タスクスイッチ、SWAPGS、SYSCALL / SYSRET に対応しました。x87 FPU、MMX、SSE / SSE2 / SSE3 / SSSE3 / SSE4.1 はサブセット実装です（SSE4.2 の文字列命令、PCLMULQDQ、AVX は未実装。MMX レジスタは x87 スタックとは別管理、FXSAVE は 32 ビット形式、XSAVE は x87 + SSE コンポーネントのみ、タスクごとの遅延 FPU 状態切替は未対応）。Secure Boot はイメージハッシュ方式（db / dbx の SHA-256 ハッシュ）のみで、証明書（X.509 / PKCS#7）の検証と認証付き変数更新には未対応です（PK 登録後は db 等を更新できません）。SetVirtualAddressMap は対応表の記録とスタブ呼び出しのアドレス変換のみで、ファームウェア側ページテーブルの再構築は行いません。UEFI 変数は VM の構成に保存され永続化されます。FAT はロングファイル名の読み書きに対応しました。Block I/O の対象は接続中のディスクイメージ、未接続時は RAM 上の FAT12 フロッピーです。ExitBootServices の後はブートサービスが無効化されます（ランタイムサービスとコンソール / GOP は継続）。UEFI のイベント通知関数はセッションループの合間に配送されます（同期的ではありません）。LoadImage のデバイスパス解決は Simple File System ボリューム上のファイルを対象とします。GOP のフレームバッファ、VGA テキスト画面、VGA モード 13h はアプリの画面表示に描画されます（モード 12h のプレーナ描画は未対応）。ARM エンジンは命令サブセットのみで、MMU や実機向け OS のブートには対応しません。大きな ISO は起動時に全体をメモリへ読み込みます。
- エミュレータは固定スペック（RISC-V: RV32IM / 1 MiB、x86: リアルモード / 16 MiB、ARM: ARMv7-A サブセット / 4 MiB）で、VM の構成値（CPU / メモリ）はまだエミュレータへ反映されません（管理用メタデータ）。
- ゲスト画面はコンソールのテキスト表示と画面表示（GOP フレームバッファ / VGA テキスト）を切り替えられます。画面表示は変更通知と 500 ミリ秒間隔ポーリングの併用で更新されます。
- VM の設定データは端末内にのみ保存されます（同期機能はありません）。
- 実機の Swift Playgrounds での動作検証は未実施です。

## ライセンス

MIT License — 詳細は [LICENSE](LICENSE) を参照してください。
