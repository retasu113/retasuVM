# Changelog

このプロジェクトの変更履歴です。バージョン形式は Semantic Versioning に従います。

## [0.8.0] - 2026-11-15

### 追加

- x86 CPU に 64 ビット ロングモードを追加した。
  - レジスタ群を 64 ビット化（R8〜R15 追加）、REX プリフィクス
    （W / R / X / B）、64 ビット オペランド、RIP 相対アドレッシング。
  - 4 階層ページング（PML4 / PDPT / PD / PT、2 MiB・1 GiB ラージ
    ページ、NX ビット、正準アドレス検査）と PAE ページング。
  - EFER MSR（LME / LMA / NXE / SCE の保持）、FS / GS ベース MSR、
    KernelGSBase、MOVSXD、IRETQ、16 バイト IDT ゲート配送、
    CR8（= LAPIC TPR）アクセス。
  - CPUID を更新（PAE / APIC ビット、ロングモード / NX 対応の
    拡張リーフ、48 ビット アドレス幅）。
- LAPIC / IOAPIC を MMIO デバイスとして追加した
  （`Engine/X86Devices.swift`）。
  - LAPIC: タイマ（ワンショット / 周期、割り込みベクタ配送）、
    SVR / TPR / PPR / EOI、IRR / ISR による優先度制御、CR8 連携。
  - IOAPIC: 24 本のリダイレクションエントリ、エッジ / レベル
    トリガ、PIT（IRQ0→GSI 2）・キーボード・シリアル・IDE の配線。
- ACPI テーブルを生成するようにした（`Engine/X86ACPI.swift`）。
  RSDP（ACPI 2.0、チェックサム 2 種）、XSDT / RSDT、FADT
  （DSDT ポインタ、リセットレジスタ宣言）、最小 DSDT（AML）、
  MADT（LAPIC / IOAPIC / ISA 割り込みオーバーライド）を
  BIOS 領域（0xE0000〜）に配置する。BIOS に INT 15h E820
  メモリマップと E801 も追加した。
- 最小 UEFI ファームウェアを追加した（`Engine/X86UEFI.swift`）。
  - PE32+（x86-64）ローダ: セクション配置を行い、ロングモードで
    エントリを呼ぶ（RCX = ImageHandle、RDX = SystemTable）。
  - ConOut プロトコル（OutputString / ClearScreen / QueryMode など）。
  - ブートサービス: AllocatePages / AllocatePool / GetMemoryMap
    （MapKey 検証付き ExitBootServices）/ Stall / CopyMem /
    SetMem / CalculateCrc32 / GetNextMonotonicCount など。
    サービスはスタブアドレスを CPU フックで横取りして実行する。
  - SystemTable の ConfigurationTable に ACPI 2.0 の GUID で
    RSDP へのポインタを登録。ランタイムサービスは ResetSystem のみ。
- 試作用サンプルを Release に添付: ロングモード検証カーネル
  （retasuVM-sample-lm.elf、ACPI 走査 + 64 ビット移行 + LAPIC /
  IOAPIC 検証）と UEFI サンプルアプリ（retasuVM-sample-uefi.efi）。
- アプリ側: x86 のイメージファイルとして .efi を選択・検証できる
  ようにし、起動方式の表示に「UEFI」を追加。設定画面と編集画面の
  説明を更新した。

### 検証

- Swift 5.10 コンパイラで全 Swift ファイル（35 件）の文法チェック
  を実施し、エラーなし。エンジン全体 + モデルの型チェックも通過。
- ロングモード検証カーネルの end-to-end テスト: 32 ビットでの
  ACPI 走査（RSDP チェックサム、XSDT→FACP→DSDT、MADT の LAPIC
  アドレス）→ 4 階層ページング + EFER で 64 ビット移行 →
  64 ビット演算・MUL / DIV・MOVSXD・CPUID・RDMSR の確認 →
  LAPIC タイマ割り込み（IRETQ 復帰）→ IOAPIC 経由キーボード
  割り込み、すべて成功。
- UEFI サンプルアプリの end-to-end テスト: ConOut 表示、
  GetMemoryMap、ExitBootServices、終了後のシリアル直接出力と
  正常停止を確認。
- 回帰テスト: BIOS ブート（El Torito ISO）、Multiboot カーネル、
  デバイス検証カーネル（TIMER / KBD / PCI / IDE / RTC）、
  RISC-V（retasuOS）、ARM（ArmDemoOS）すべて従来どおり動作。
  ※ デバイス検証カーネルの IDE READ チェックは、アプリ内蔵の
  空 RAM ディスクではパターン不一致のため NG 表示になる
  （読み取り自体は成功。検証用パターン入りディスクを接続した
  ハーネスでは v0.7.0 時点で確認済み）。

### 既知の制限

- UEFI は最小実装のため、Windows Boot Manager や GRUB は起動
  できない（Block I/O、Simple File System、変数サービス、
  プロトコル検索が未提供）。一般の OS（Windows / 現在の Linux）
  は引き続き実行できない。
- SYSCALL / SYSRET は未実装。リング 0 のみ（ユーザーモードなし）。
- 実機の Swift Playgrounds での動作検証は未実施。

## [0.7.0] - 2026-11-15

### 追加

- x86 に PC 周辺デバイスのエミュレーションを追加した
  （`Engine/X86Devices.swift`、デバイスバス方式）。
  - 割り込みコントローラ 8259A PIC（マスタ + スレーブ）: 再マップ、
    マスク、EOI、優先順位制御。ハードウェア割り込みをリアルモード
    （IVT）/ プロテクトモード（IDT）の両方へ配送する。
  - タイマ 8254 PIT: チャンネル 0 の周期割り込み（IRQ0）など。
  - キーボードコントローラ 8042: コンソール入力をスキャンコード
    （セット 1）化し、IRQ1 で通知する。
  - PCI ホストブリッジ: コンフィギュレーション機構 #1（0xCF8 /
    0xCFC）。ホストブリッジ、ISA ブリッジ、IDE、VGA の 4 デバイス。
  - IDE（ATA）コントローラ: PIO 転送で IDENTIFY / READ / WRITE
    SECTORS に対応し、BIOS（INT 13h）とディスクイメージを共有する。
    Multiboot 起動時は 16 MiB の RAM ディスクを接続する。
  - RTC / CMOS（現在時刻）、シリアル 16550 相当（割り込み対応）、
    VGA レジスタ、ポート 0xE9 デバッグコンソールなど。
  - HLT は割り込み待ちのアイドルとして動作するようになった
    （タイマ等で目覚める）。STI / SS ロード直後の割り込みシャドウも再現。
- 試作用のデバイス検証カーネル（retasuVM-sample-devices.elf）を
  Release に添付。PIC / PIT / キーボード / PCI / IDE / RTC の動作を
  順に確認して結果を表示する。

### 修正

- INS / OUTS 命令（0x6C〜0x6F）が未実装だった問題を修正した。
  デバイス検証カーネルの実行テストで発見したもの。

### 検証

- Swift 5.10 コンパイラで全 Swift ファイル（33 件）の文法チェックを
  実施し、エラーなしを確認。型名の重複もなし。
- デバイス検証カーネルの end-to-end テストで TIMER（PIC 再マップ +
  PIT IRQ0 + HLT 復帰）、KBD（IRQ1 + スキャンコード）、PCI（列挙）、
  IDE（IDENTIFY / READ / WRITE + IRQ14）、RTC のすべてが OK になる
  ことを確認。
- Multiboot カーネル、プロテクトモード移行、リアルモード（El Torito /
  raw）、ARM、RISC-V の全回帰テストと保存データの後方互換も再確認。

### 既知の制約

- IDE は PIO 転送のみ（バスマスタ DMA なし）。フロッピーは BIOS
  経由のみで、FDC のエミュレーションはない。
- VGA はレジスタとテキストメモリ（0xB8000）の保持のみで、コンソール
  への画面描画は行わない（出力はシリアル / INT 10h 経由）。
- Multiboot 起動時の RAM ディスクは電源オフで内容が消える。
- Windows や現在の Linux は、UEFI / ロングモードや ACPI など残りの
  要素が別途必要なため、まだ起動できない。
- SwiftUI 部分の型チェックと、実機（iPad / iPhone）の Swift Playgrounds
  での検証は未実施。

## [0.6.0] - 2026-11-15

### 追加

- x86 エミュレータに 32 ビット プロテクトモードを実装した。
  - セグメントディスクリプタ（GDT / LDT）と隠しキャッシュ、LGDT /
    LIDT / LLDT、コントロールレジスタ（CR0 / CR2 / CR3 / CR4）。
  - 32 ビットアドレッシング（ModR/M + SIB）と、CS の D ビットに
    連動するオペランド / アドレスサイズ。
  - ページング（4 KiB / 4 MiB ページ、A / D ビット更新、#PF 配送と
    CR2 設定）。
  - IDT ゲート経由の割り込み / 例外配送（割り込みゲート・トラップ
    ゲート、エラーコード付き）、IRET、CPUID、MOV CR / DR、
    RDMSR / WRMSR スタブ、SETcc / CMOVcc / BSWAP など。
  - ブートセクタから GDT を設定してプロテクトモードへ移行する
    従来型のブート手順がそのまま動作する。
- Multiboot（バージョン 1）ブートローダを実装した
  （`Engine/Multiboot.swift`）。
  - Multiboot 対応 ELF32（i386）カーネルを直接起動できる
    （ELF プログラムヘッダ方式と a.out クルージュの両対応）。
  - ISO のルートに置かれた KERNEL.ELF も自動で検出して起動する。
  - 情報構造体（メモリ情報、ブートデバイス、メモリマップ）を提供。
  - 試作用サンプルカーネル（retasuVM-sample-kernel.elf）を Release に
    添付。Multiboot で起動し、メモリ情報を表示して、自らページングを
    有効化する。

### 検証

- Swift 5.10 コンパイラで全 Swift ファイル（32 件）の文法チェックを
  実施し、エラーなしを確認。型名の重複もなし。
- Multiboot: サンプルカーネルの end-to-end 起動（マジック確認、
  mem_upper = 15360 KiB の読み取り、カーネル自身によるページング
  有効化、正常停止）を確認。ISO 内 KERNEL.ELF からの起動も確認。
- プロテクトモード: ブートセクタ → ステージ 2 が GDT を設定して
  32 ビットへ移行し、SIB アドレッシング、CPUID、IDT 経由の
  ソフトウェア割り込み（int 0x80 → ハンドラ → iretd）、ページング
  有効化、未マップ領域アクセスでの #PF 配送と CR2 を実行テストで確認。
- リアルモード（El Torito / raw ブート）、ARM、RISC-V の全回帰
  テストと保存データの後方互換も再確認。

### 既知の制約

- プロテクトモードはリング 0 のみ。タスクスイッチ（TSS 切り替え）と
  ユーザーモード、仮想 8086 モードには対応しない。
- UEFI は未実装。Windows や現在の Linux は、ブート方式と周辺
  デバイス（割り込みコントローラ、タイマ、PCI、ストレージ等）の
  再現が別途必要なため、まだ起動できない。起動できるのは Multiboot
  対応カーネルやリアルモード / プロテクトモードの自作 OS など。
- SwiftUI 部分の型チェックと、実機（iPad / iPhone）の Swift Playgrounds
  での検証は未実施。

## [0.5.0] - 2026-11-15

### 追加

- x86 エミュレータを自作し、BIOS ブートで x86 のブートプログラムが
  動くようになった。
  - `Engine/X86CPU.swift`: 16 ビット リアルモード CPU。命令デコード
    （ModR/M、prefix、文字列操作、シフト、乗除算、far ジャンプ等）と
    フラグ計算を実装。シリアルポート（COM1）はコンソールに接続。
  - `Engine/X86BIOS.swift`: ファームウェア相当の BIOS サービス層。
    ブートセクタを 0x7C00 へ読み込んで開始し、INT 10h（画面）/
    INT 13h（ディスク、CHS と LBA パケット）/ INT 16h（キーボード）/
    INT 12h / INT 1Ah / INT 15h に応答する。
  - `Engine/ElTorito.swift`: ISO 9660 の El Torito 拡張パーサ。
    ブートカタログを検証し、フロッピー / ハードディスク /
    エミュレーションなしのブートイメージを取り出す。
  - 試作用サンプル ISO（retasuVM-sample-x86.iso）を Release に添付。
    手書きの x86 ブートセクタが BIOS 経由で表示・ディスク読み取り・
    キーエコーを行う。
- ARM エミュレータを自作した。
  - `Engine/ARMCPU.swift`: ARMv7-A（A32）命令サブセット
    （データ処理・乗算・ロード / ストア・ブロック転送・分岐・SVC）。
    システムコールは SVC 即値で呼び出す。
  - `Engine/ARMAssembler.swift`: 自作の ARM アセンブラ
    （条件サフィックス、回転即値、リテラルプール対応）。
  - デモゲスト「ArmDemoOS」（help / fact / echo / quit）を追加。
- VM ごとに CPU アーキテクチャ（RISC-V / x86 / ARM）を選べるようにした。
  編集画面にアーキテクチャ選択を追加し、一覧・詳細・コンソールの
  表示とクイックコマンドがアーキテクチャに連動する。
- セッションの共通インターフェース `GuestSession` を導入し、
  VMStore が 3 エンジンを同じ仕組みで扱えるようにした。

### 互換性

- v0.4.0 以前の保存データ（architecture キーが無い JSON）も読み込める
  （未設定の場合は RISC-V として扱う）。

### 検証

- Swift 5.10 コンパイラで全 Swift ファイルの文法チェック（パース）を
  実施し、エラーなしを確認。型名の重複もなし。
- x86: El Torito パーサの単体確認と、サンプル ISO からの end-to-end
  ブート（BIOS 表示、INT 13h セクタ読み取り、キーエコー、HLT まで）を
  実行テストで確認。raw フロッピーイメージからのブートも確認。
- ARM: ArmDemoOS の対話テスト（fact で 12! = 479001600、echo、quit）と
  命令単体テスト（add / cmp / 分岐 / ldr / str / bl / push / pop /
  回転即値）を確認。
- RISC-V 側の全ゲスト回帰テストと保存データの後方互換も再確認。

### 既知の制約

- x86 はリアルモードのみ。UEFI やプロテクトモード / ロングモードには
  対応しないため、Windows や現在の Linux のインストール ISO は
  起動できない。
- ARM は命令サブセットのみで、MMU や実機向け OS のブートには
  対応しない。
- SwiftUI 部分の型チェックと、実機（iPad / iPhone）の Swift Playgrounds
  での検証は未実施。

## [0.4.0] - 2026-11-15

### 追加

- ISO ファイルから起動できるようになった。
  - VM の作成・編集で起動方法を「ISO ファイル」にし、ファイル App から
    .iso を選ぶとアプリ内にコピーして保持する（検証で形式エラーや
    BOOT.BIN の無い ISO はその場で弾く）。
  - 起動時に ISO 9660 を解析し、ルート直下の `BOOT.BIN`（RISC-V RV32IM
    フラットバイナリ）を読み込んで実行する。
  - ISO 全体はディスクとして装着され、ゲストがシステムコールで読み取れる
    （a7=20: セクタ数、a7=21: セクタ読み取り、a7=22: バイト数）。
- ISO 9660 パーサ（`Engine/ISO9660.swift`）を実装。
- ISO ブート確認用ゲスト「IsoDemoOS」を追加し、試作用のサンプル ISO
  （retasuVM-sample.iso）を Release に添付。IsoDemoOS は自分が起動した
  ディスクの容量・形式・ボリュームラベルを表示する（コンソールで `info`）。

### 互換性

- v0.3.0 以前の保存データ（ISO 関連キーが無い JSON）もそのまま読み込める
  （未設定の場合はゲストイメージ起動として扱う）。

### 検証

- Swift 5.10 コンパイラで全 Swift ファイル（22 件）の文法チェック（パース）を
  実施し、エラーなしを確認。型名の重複もなし。
- エミュレータ core を型チェック付きでビルドし、実行テストを実施:
  ISO パーサ（ラベル・ファイル抽出・異常系）、サンプル ISO からの
  end-to-end ブート（IsoDemoOS がディスク情報を表示）、ディスクなし時の
  システムコール、全ゲストの回帰、保存データの後方互換、すべて通過。
- サンプル ISO は ISO 9660 として検証済み（BOOT.BIN の抽出が一致）。
- SwiftUI 部分の型チェックと実機（iPad / iPhone）Swift Playgrounds での
  検証は未実施。

### 既知の問題

- 起動できる ISO は retasuVM 形式（BOOT.BIN 入り）のみ。一般の OS の
  インストール ISO（Ubuntu など）は CPU アーキテクチャとブート方式が
  異なるため起動できない。
- エミュレータは固定スペック（RV32IM、メモリ 1 MiB）で、VM 構成値は未反映。
- ゲスト画面はテキストコンソールのみ。
- アプリアイコンはプレースホルダ。

## [0.3.0] - 2026-11-15

### 追加

- 複数のゲスト OS イメージを選んで起動できるようになった（VM の作成・編集で選択）。
  - retasuOS: 対話型モニタ（従来のゲスト）
  - PlayOS: 数当てゲームとサイコロ（乱数システムコール使用）
  - CalcOS: スタック式（RPN）計算機（M 拡張の乗除算を使用）
- CPU エミュレータに M 拡張（mul / mulh / mulhsu / mulhu / div / divu / rem / remu）を追加。
- 乱数システムコール（a7=6、xorshift32）を追加。
- ゲスト共通ランタイム（GuestRuntime）を分離し、ゲスト追加が容易になった。
- サンプル VM を 3 台（各イメージ 1 台）に拡充。
- コンソールのクイックコマンドがゲストイメージごとに切り替わるようになった。

### 修正

- エンジン側のゲスト定義 `GuestOS` がモデル側の `GuestOS` 列挙型と名前衝突していた
  問題を修正（エンジン側を `RetasuOS` に改名）。v0.2.0 は実機コンパイル時に
  エラーになる状態だったため、本バージョンで解消した。

### 互換性

- v0.2.0 以前の保存データ（guestImage キーが無い JSON）もそのまま読み込める
  （未設定の場合は retasuOS として扱う）。

### 検証

- Swift 5.10 コンパイラで全 Swift ファイル（20 件）の文法チェック（パース）を実施し、
  エラーなしを確認。
- エミュレータ core（CPU・アセンブラ・全ゲスト・セッション・モデル）を型チェック付きで
  ビルドし、実行テストを実施: M 拡張の演算、PlayOS の数当て（正解・ヒント・サイコロ）、
  CalcOS の一連の計算とエラー処理、retasuOS の回帰、保存データの後方互換、すべて通過。
- SwiftUI 部分の型チェックと実機（iPad / iPhone）Swift Playgrounds での検証は未実施。

### 既知の問題

- 実行できるゲストは同梱の 3 イメージのみ。一般の OS（Linux / Windows など）は実行できない。
- エミュレータは固定スペック（RV32IM、メモリ 1 MiB）で、VM 構成値は未反映。
- ゲスト画面はテキストコンソールのみ。
- アプリアイコンはプレースホルダ。

## [0.2.0] - 2026-11-15

### 追加

- RISC-V RV32I ソフトウェア CPU エミュレータ（`RISCVCPU`）。ゲストコードを実際に実行する。
- RISC-V 用の小さなアセンブラ（`RISCVAssembler`）。ゲスト OS をアプリ内で機械語に変換する。
- ゲスト OS「retasuOS」（アセンブリ実装の対話型モニタ）。コマンド: help / echo / fib / about / ver / clear / halt。
- 対話型コンソール: コマンド入力欄とクイックコマンド。ゲストの出力がリアルタイムに流れる。
- 一時停止は CPU 実行の停止（メモリ保持）、再起動はセッション再作成として実装。

### 変更

- 実行エンジンをシミュレーションから実エミュレータに置き換え。
- サンプル VM の構成をエミュレータの実スペックに合わせて調整。

### 検証

- エミュレータ core（CPU・アセンブラ・ゲスト OS・セッション）を Swift コンパイラで
  ビルドし、対話テスト（help / fib 20 = 6765 / echo / halt など）の通過を確認した。
- 実機（iPad / iPhone）の Swift Playgrounds での動作検証は未実施。

### 既知の問題

- エミュレータは固定スペック（RV32I、メモリ 1 MiB）で、VM 構成の CPU / メモリ値は
  まだエミュレータへ反映されない（管理用メタデータ）。
- Linux や Windows など一般の OS は実行できない（iOS ではハードウェア仮想化が使えないため）。
- ゲスト画面はテキストコンソールのみ（グラフィカルな画面描画はない）。
- アプリアイコンはプレースホルダ。

## [0.1.0] - 2026-11-15

### 追加

- 初期リリース。
- 仮想マシンの一覧・検索・作成・編集・削除。
- 起動 / 一時停止 / 再開 / 再起動 / 停止 / 強制停止の状態遷移（シミュレーションエンジン）。
- 状態をシンボル＋ラベルで表示するステータスバッジ（色だけに頼らない表示）。
- 破壊的操作への確認ダイアログ。
- コンソール画面（ゲスト画面プレースホルダ＋操作ログ）。
- iPad 向け NavigationSplitView、iPhone 向け TabView + NavigationStack の適応レイアウト。
- ダークモード / Dynamic Type / VoiceOver / Reduce Motion への配慮。
- VM 設定の端末内永続化（JSON）。

### 既知の問題

- 実行エンジンはシミュレーションであり、実際の仮想化は行わない。
- ゲスト画面はプレースホルダ表示。
- アプリアイコンはプレースホルダ。
