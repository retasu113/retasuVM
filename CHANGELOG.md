# Changelog

このプロジェクトの変更履歴です。バージョン形式は Semantic Versioning に従います。

## [0.14.0] - 2026-11-15

### 追加

- サンプルをすべてアプリに内蔵した（17 種）。
  - x86: Multiboot カーネル、ロングモード / 特権リング / 周辺デバイス / DMA /
    タスクスイッチ / FPU・SSE / CPU 拡張 / macOS 基盤の各検証カーネル、
    BIOS ブート ISO、UEFI アプリ 6 種。RISC-V: BOOT.BIN 入りサンプル ISO。
  - VM の編集画面で「ファイル / 内蔵サンプル」を切り替え、サンプルを
    選ぶだけで起動できる。内蔵データの SHA-256 は配布サンプルと一致する
    ことをテストで検証した（起動時にファイルは不要）。
- ARM64（AArch64）エミュレータを追加した。
  - iOS / iPadOS 上で Mac を動かす Henge の方式（ARM64 の Apple Silicon
    Mac エミュレーション + Apple 公式リストアイメージの取得）を参考に、
    macOS 実行へ向けた基盤として実装した。
  - CPU コア: EL0 / EL1、例外ベクタと ERET、命令セット（データ処理、
    分岐、ロード / ストア、アトミック命令群、システム命令）。
  - 段 1 MMU（4KB グラニュール、TTBR0 / TTBR1、権限チェック、
    アクセスフラグ / 変換 / 権限フォールトの ESR・FAR 付き配送）。
  - GIC ライト（ディストリビュータ + CPU インタフェース）、
    仮想タイマ（CNTP / CNTV、INTID 30）、PL011 風 UART、ELF64 ローダ。
  - 自作アセンブラ（出力が clang と一致することをコーパスで検証）と
    デモゲスト「Arm64DemoOS」（help / fact / echo / quit）。

### 修正

- 全ファイルのバグ監査で見つけた、ARM64 の命令デコードとアセンブラの
  不具合を修正した。
  - 条件分岐（B.cond）の条件フィールドの取り違え。
  - LSE アトミック命令の照合パターンがレジスタオフセット形式の
    ロード / ストアと衝突していた問題と、SWP の識別ビットの誤り。
  - LDR リテラル（64 ビット）のサイズ指定フィールドの誤り。
  - ペア命令（LDP / STP）のモード判定と要素サイズの誤り。
  - CCMP / CCMN と HINT（WFI）の照合パターンが到達不能だった問題
    （WFI でアイドルにならなかった）。
  - 仮想タイマのシステムレジスタキー（CNTP_TVAL など）の誤りで
    タイマ設定が無視されていた問題。
  - CAS の比較結果の書き戻し先レジスタの誤り。
  - REV のオペコードの誤り（REV32 との混同）。
  - アセンブラ: シフト付きレジスタ形式（add / sub / 論理演算）、
    `mov sp, レジスタ`、`mov レジスタ, #-1`、64 ビットを超える
    16 進即値、32 ビット幅の cmp / cmn と符号拡張命令の幅の誤り。

### 変更

- リリース方針を変更し、本バージョンから正式リリースとして公開する
  （以後は Pre-release にしない）。GitHub Actions のワークフロー、
  REQUIREMENTS.md、BUILD.md の記述も合わせた。

### 検証

- 新規統合テストに合格: ARM64 カーネル（算術 / アトミック / 独占 /
  タイマ割り込み / MMU の権限・アクセスフラグ・変換フォールト /
  EL0 実行の全 29 項目）、ARM64 アセンブラのコーパス一致
  （clang と 104 ワード完全一致）、内蔵サンプルのハッシュ一致
  （17 種すべて）、Arm64DemoOS の対話実行。
- 全回帰テストに合格: x86 Multiboot カーネル群（基本 / リング /
  ロングモード / デバイス / DMA / タスク / FPU / CPU 拡張 / macOS 基盤）、
  UEFI アプリ 6 種、BIOS ブート ISO、RISC-V（fib 46）、ARM（12!）、
  構成データの互換デコード、UEFI 変数の永続化。
- 全 Swift ファイルの型チェックと構文チェックに合格。
- 実機（iPhone / iPad の Swift Playgrounds）での検証は未実施。

### 注意

- macOS 自体はまだ起動しない。ARM64 基盤の上にデバイツリー（ADT）、
  iBoot / リストア手順、NVMe、仮想 GPU が必要で、今後の段階で実装する。
  インストールイメージは Henge と同様、Apple のものをアプリ内で
  取得する形を予定しており、アプリには同梱しない。
- ARM64 エンジンはインタプリタ方式で、SIMD / 浮動小数点、EL2 / EL3、
  LDXP / STXP、ポインタ認証は未実装。

## [0.13.0] - 2026-11-15

### 追加

- macOS（XNU）の起動基盤を追加した。
  - CPUID: ベンダ文字列を「GenuineIntel」に変更し、リーフ 1 の署名を
    family 6 / model 142（Coffee Lake、i5-8259U 相当）にした。
    リーフ 0x80000002〜0x80000004 のブランド文字列も返す。
  - HPET: MMIO 0xFED00000 に 64 ビット メインカウンタ（10 MHz）と
    タイマ 3 本を実装。IOAPIC ルーティングとレガシー置換
    （タイマ 0 → IRQ0、タイマ 1 → IRQ8）に対応。ACPI HPET テーブルと
    DSDT の HPET デバイス（PNP0103、_CRS 付き）も追加した。
  - Apple SMC: I/O ポート 0x300 / 0x304 のキープロトコル
    （読み取り / 書き込み / インデックス取得 / キー情報）を実装し、
    OSK0 / OSK1 キー（64 バイトの文字列）、#KEY、REV、MSLD、BNum を
    返す。DSDT に SMC デバイス（APP0001）も宣言した。
  - AHCI (SATA): PCI デバイス 3 に AHCI 1.3 コントローラを追加
    （BAR5 = 0xFEB00000）。コマンドリスト / レジスタ FIS / PRDT で
    IDENTIFY DEVICE、READ / WRITE DMA (EXT)、FLUSH CACHE を実行する。
    ディスクは IDE と共有する。
  - SMBIOS: 2.7 形式のテーブル（タイプ 0 / 1 / 2 / 3 / 4 / 17）を
    0xE2000 に配置し、システム情報を iMac19,1 として提示する。
    UEFI の構成テーブルにも SMBIOS GUID で登録した。

### 検証

- 新規統合テスト（macOS 基盤カーネル: CPUID、ACPI の HPET テーブル探索と
  チェックサム、HPET カウンタとタイマ割り込み、SMC の OSK キー一致、
  SMBIOS の機種名、AHCI の IDENTIFY と読み書き往復）と全回帰テストに合格。
- 実機（iPhone / iPad の Swift Playgrounds）での検証は未実施。

### 注意

- 本バージョンは macOS の「起動基盤」であり、macOS 自体はまだ起動しない。
  Apple 純正ブートローダ (boot.efi) の互換性検証と、XNU のハードウェア
  チェックへの対応（および利用者自身の macOS インストールイメージ）が
  別途必要。

## [0.12.0] - 2026-11-15

### 追加

- x86 CPU に MMX を実装した（64 ビット整数 SIMD 一式と
  EMMS。レジスタは x87 スタックとは別管理）。
- SSE3（MOVSLDUP / MOVSHDUP / MOVDDUP / HADD / HSUB /
  ADDSUB / LDDQU）、SSSE3（PSHUFB / PHADD / PHSUB /
  PMADDUBSW / PSIGN / PMULHRSW / PABS）、SSE4.1
  （PMOVSX / PMOVZX / BLEND / PBLEND / DPPS / DPPD /
  ROUND / PINSR / PEXTR / INSERTPS / MPSADBW / PMULLD /
  PMULDQ / PCMPEQQ）を実装した。CPUID リーフ 1 / 7 を
  拡張し、SSE3 / SSSE3 / SSE4.1 / POPCNT / MOVBE /
  XSAVE などを申告するようになった。
- POPCNT、MOVBE、RDTSC / RDTSCP（IA32_TSC_AUX MSR）、
  CMPXCHG8B / CMPXCHG16B を実装した。
- XSAVE / XRSTOR / XSAVEOPT と XGETBV / XSETBV を実装
  した（XCR0 は x87 + SSE コンポーネントのみ）。
- CR0.TS セット時の #NM 配送、FLDENV / FNSTENV の
  完全な環境転送、FNSAVE / FRSTOR、FISTTP を実装した。
- UEFI に本物のメモリアロケータを実装した。ページの
  空き管理とプールのフリーリストで FreePages / FreePool
  が実際に回収し、AllocatePages の AnyPages /
  MaxAddress / Address、UnloadImage の領域回収に対応
  した。GetMemoryMap は実際の確保状況を反映する。
- UEFI に Secure Boot（イメージハッシュ方式）を実装
  した。SecureBoot / SetupMode 変数、PK 登録による
  ユーザーモード移行、db / dbx の署名リスト（SHA-256
  ハッシュ）による LoadImage の検証に対応した。
  Authenticode ハッシュ計算のため SHA-256 を新規実装
  した（Engine/SHA256.swift）。証明書（X.509）の検証は
  未対応。
- GOP が 640×400 / 800×600 / 1024×768 の 3 モードに
  対応した（QueryMode / SetMode）。
- CreateEventEx のイベントグループ GUID（ExitBootServices /
  SetVirtualAddressMap グループ）に対応した。
- SetVirtualAddressMap を実装した。ランタイム領域の
  対応表を記録し、ConvertPointer と仮想アドレス経由の
  ランタイムサービス呼び出しに対応した。メモリマップは
  ランタイム属性と VirtualStart を正しく報告する。
- VGA モード 13h（320×200、256 色）に対応した。BIOS
  INT 10h のモード設定、DAC パレット、アプリの画面
  表示への描画に対応する（モード 12h は未対応）。
- アプリの画面表示が変更通知に対応した（チェックサムで
  変化を検出して即時更新し、ポーリングは 500 ミリ秒
  間隔に緩和）。
- アプリアイコンを設定した（レタスの葉とモニタを
  モチーフにしたアイコン）。

### 修正

- CLTS（0F 06）が CR0.TS を実際にはクリアして
  いなかった。
- RDTSC（0F 31）が未実装だった（CPUID では TSC を
  申告していた）。
- x87 の DD /4・/5 の割り当て違いを直した（正しくは
  FRSTOR / FUCOM m64）。
- SSSE3 の水平演算（PHADD / PHSUB 系）を 64 ビット
  単位で処理し、dest / src のペア順序が混ざっていた。
- SSSE3 / SSE4.1 / 0F 3A のオペコード割り当てずれを
  直した（PMADDUBSW / PSIGN / PMULHRSW / PCMPEQQ /
  PMULDQ / ROUND 系 / PEXTRD・PEXTRQ）。
- DPPS / DPPD の即値マスク（積和対象マスクと書き込み
  マスク）が逆だった。
- 80 ビット拡張精度の読み込みで指数部の上位バイトが
  落ち、大きな値が 0 になっていた（FRSTOR / FLD m80 /
  FXRSTOR の x87 復元に影響）。
- Secure Boot の証明書種別 GUID（EFI_CERT_SHA256）の
  定数タイポを直した。
- 変数の列挙（GetNextVariableName）で、ファームウェア
  合成変数（SecureBoot / SetupMode）をゲスト変数の
  後ろに並べるよう変更した（列挙順は仕様上不定だが、
  順序に依存するアプリとの互換性のため）。

### 検証

- 新規統合テスト: CPU 拡張カーネル（MMX / SSE3 /
  SSSE3 / SSE4.1 / POPCNT / MOVBE / RDTSCP /
  CMPXCHG8B・16B / XSAVE・XRSTOR / FISTTP /
  FNSAVE・FRSTOR / FLDENV / #NM ハンドラ / VGA
  モード 13h の描画とパレット確認）、UEFI5（アロ
  ケータ、GOP モード切替、CMPXCHG16B、Secure Boot
  の登録・検証・dbx 優先の拒否・未登録の拒否・
  ユーザーモードでの db 更新拒否、CreateEventEx
  グループ通知、SetVirtualAddressMap + CR3 切替後の
  仮想アドレス経由 GetTime）。すべて合格。
- 全回帰テスト（リング / DMA / ロングモード /
  デバイス / Multiboot / タスクスイッチ・SWAPGS /
  FPU・SSE / BIOS ISO / UEFI サンプル 4 種 / LFN /
  変数永続化 / RISC-V / ARM / Codable 寛容デコード）
  合格。全 37 ファイルの文法チェックとエンジン +
  モデルの型チェック合格。
- 実機（iPhone / iPad の Swift Playgrounds）での検証は未実施。

## [0.11.0] - 2026-11-15

### 追加

- x86 CPU に x87 FPU を実装した。全メモリ形式（32 / 64 ビット
  浮動小数点、16 / 32 / 64 ビット整数、80 ビット拡張精度）と
  レジスタ形式、FCMOVcc、FUCOMI / FCOMI（EFLAGS へ反映）、
  超越関数（FSIN / FCOS / FSINCOS / FPTAN / FPATAN /
  FYL2X 系 / FSCALE / FXTRACT / FPREM 系 / FRNDINT）、
  FNSTSW / FNINIT / FNCLEX、FLDENV / FNSTENV（制御 /
  状態ワード）に対応。制御ワードの丸め制御を FIST に反映し、
  CR0.EM のときは #NM を出す。
- x86 CPU に SSE / SSE2 サブセットを実装した。転送
  （MOVAPS 系 / MOVDQA 系 / MOVD / MOVQ）、浮動小数点演算
  （ADD / SUB / MUL / DIV / MIN / MAX / SQRT、PS / PD / SS /
  SD）、比較、変換（CVT 系）、整数演算（PADD / PSUB 系、
  飽和演算、PACK / PUNPCK、シフト）、シャッフル、FXSAVE /
  FXRSTOR、LDMXCSR / STMXCSR に対応。CPUID で FXSR /
  SSE / SSE2 を申告するようになった。
- UEFI に ConIn（Simple Text Input プロトコル）を追加した。
  アプリのコンソール入力がキー入力として届き、ReadKeyStroke
  と WaitForEvent イベントで受け取れる。
- UEFI のイベント通知関数（NotifyFunction）を実際に呼ぶ
  ようになった。SignalEvent、タイマ期限、プロトコル
  インストール（RegisterProtocolNotify）、ExitBootServices
  と SetVirtualAddressMap のイベントグループで通知が配送
  される。配送はセッションループの合間にゲストコールとして
  実行し、終了後にレジスタとスタックを復元する。
- UEFI の ConnectController / DisconnectController が
  Driver Binding プロトコルを持つドライバの Supported /
  Start / Stop を呼ぶようになった（ドライババインディング）。
- LoadImage がデバイスパス（FilePath ノード）経由で Simple
  File System ボリューム上のファイルから読み込めるように
  なった。
- アプリのコンソールに「画面」表示を追加した。UEFI の GOP
  フレームバッファ（640×400 BGRA）と VGA テキスト画面
  （80×25）を描画し、コンソール表示と切り替えられる。
  250 ミリ秒間隔で更新する。
- セッションの実行チャンクを 50,000 命令から 200,000 命令
  へ増やした。スピン待ちするゲスト（UEFI アプリのポーリング
  など）の実行速度が大幅に改善した。

### 検証

- 新規統合テスト: FPU / SSE 検証カーネル（FLD / FADDP /
  FILD / FSQRT / FCOMPP、ADDPS / PADDD / CVTTSS2SI、
  FXSAVE → FXRSTOR の往復）、UEFI4（ConIn の読み取りと
  WaitForEvent、イベント通知、プロトコル通知、ドライバの
  Supported / Start / Stop、デバイスパス経由の LoadImage、
  ExitBootServices イベントグループ通知）。すべて合格。
- 全回帰テスト（リング / DMA / ロングモード / デバイス /
  Multiboot / タスクスイッチ・SWAPGS / BIOS ISO / UEFI
  サンプル 3 種 / LFN / 変数永続化 / RISC-V / ARM /
  Codable 寛容デコード）合格。全 36 ファイルの文法
  チェックとエンジン + モデルの型チェック合格。
- 実機（iPhone / iPad の Swift Playgrounds）での検証は未実施。

### 既知の制限

- Secure Boot、TPM、カプセル / ESRT は未提供。
  SetVirtualAddressMap は恒等マップ前提の受理のみで、仮想
  アドレスへの変換は行わない。一般の OS（Windows /
  現在の Linux）はまだ起動できない。
- 通知関数の配送はセッションループの合間（同期的ではない）
  で、同時に 1 つずつ。WaitForEvent は最大 30 秒で打ち切る。
- FPU の FLDENV / FNSTENV は制御 / 状態ワードのみ転送する。
  FXSAVE は全モードで 32 ビット形式。CR0.TS による #NM
  （遅延 FPU 切替）は未対応。SSE は SSE / SSE2 のサブセット
  で、SSE3 以降と MMX レジスタは未実装。
- LoadImage のデバイスパス解決は Simple File System
  ボリューム上のファイルを対象とする。
- アプリの画面表示はポーリング更新（250 ミリ秒間隔）。

## [0.10.0] - 2026-11-15

### 追加

- x86 CPU に SWAPGS 命令と TSS ハードウェアタスクスイッチを実装した。
  JMP / CALL FAR → TSS ディスクリプタ / タスクゲート、割り込み
  ゲート（種別 5）、NT フラグ付き IRET によるタスク切替に対応し、
  状態の保存 / 復元、ビジービット管理、CR0.TS の設定を行う。
  検証カーネルで JMP FAR 往復と SWAPGS の往復を確認した。
- UEFI に Loaded Image プロトコルを追加し、LoadImage /
  StartImage / Exit / UnloadImage を実装した。メモリバッファから
  PE32+ を読み込み（希望 ImageBase が空いていない場合は
  DIR64 再配置を適用）、子イメージへ制御を移して終了ステータスを
  受け取れる。
- UEFI に GOP（Graphics Output Protocol）を追加した。
  640×400（BGRA）の線形フレームバッファ、QueryMode / SetMode /
  Blt（VideoFill / BufferToVideo / VideoToBuffer / VideoToVideo）。
- UEFI にイベント / タイマサービスを追加した。CreateEvent /
  CreateEventEx / SetTimer（周期・相対）/ WaitForEvent /
  SignalEvent / CloseEvent / CheckEvent。
- UEFI の残りのサービスを実装した。LocateHandle（呼び出し側
  バッファ形式）、LocateDevicePath、ReinstallProtocolInterface、
  Install / UninstallMultipleProtocolInterfaces、
  OpenProtocolInformation、ConnectController /
  DisconnectController（即成功）、RegisterProtocolNotify、
  ランタイムの GetTime / SetTime / GetWakeupTime /
  SetWakeupTime / SetVirtualAddressMap / ConvertPointer /
  GetNextHighMonotonicCount。
- UEFI 変数を永続化した。セッション終了時に VM の構成へ保存し、
  次回起動時に引き継ぐ（保存データ形式は後方互換）。
- ExitBootServices の後はブートサービス呼び出しがエラー
  （EFI_NOT_READY）を返すようになった。ランタイムサービスと
  コンソール / GOP は継続して使える。
- FAT の書き込みでロングファイル名（LFN）に対応した。
  LFN エントリの生成、上書き時のエントリ再利用、削除時の
  LFN エントリ除去、列挙時のチェックサム検証。

### 修正（全 Swift ファイル監査で見つけた確定バグ）

- x86 ページングで R/W ビットを検査していなかった（リング 3 から
  読み取り専用ページへ書き込めた）。全階層の AND で判定し、
  CPL 3 と CR0.WP 有効時のリング 0 で #PF を出すよう修正。
- 特権検査の漏れ: OUT imm8、INS / OUTS に IOPL 検査がなかった。
  POPF が IOPL / IF を無条件に書き換えた。Far 転送に CS の
  DPL 検査がなかった（リング昇格が可能だった）。
- IDIV が Int 最小値 / -1 などで Swift のトラップでプロセス
  ごと落ちた。除算前に #DE として弾くよう修正。
- UEFI の PE 判定で Subsystem を 4 バイト読みしていたため、
  DllCharacteristics が非ゼロの通常の .efi を UEFI アプリと
  認識できず BIOS 起動に落ちていた。2 バイト読みに修正。
- GetNextMonotonicCount が引数を RDX に書いていた（正しくは
  RCX）。Block I/O で巨大 LBA が Int 変換でトラップした。
  GetMemoryMap が失敗時にも MapKey を進めていた。
- 保存データのデコードを寛容にした。未知の enum 値や型の
  不一致で全 VM が消える問題を修正し、デコード不能時は
  ファイルを退避してからサンプルへ戻すようになった。
- VGA アトリビュートレジスタの範囲外アクセス、Multiboot
  a.out クルージュの減算アンダーフローで落ちる問題を修正。
- ARM アセンブラの範囲外即値でのトラップ、リテラルプールの
  負オフセット拒否、ldrb のバイトフラグ欠落、lsl #32 の
  誤エンコードを修正。RISC-V アセンブラの即値切り捨てを
  エラーにするよう修正。ARMDemoOS の行入力に上限を追加し、
  RetasuOS の fib 上限を 46 に修正（47 以上で値が化けた）。
- FAT の短い名前生成が 21 バイト返してディレクトリを壊す
  問題、FAT 種別判定のオフバイツー、破損 BPB でのクラッシュ、
  LFN ファイル上書き時のエントリ重複を修正。
- IDE の範囲外 LBA が成功扱いだった問題、PCI CONFIG_ADDRESS
  の部分書き込み、PIT モード 6 / 7、BIOS INT 1Ah の
  24 時間ラップ値などを仕様どおりに修正。
- そのほか監査で確認した細かな仕様ずれ（#PF の U/S ビット、
  非正準アドレスの #GP 化、IRET の SS/ESP 復元、REP 文字列
  命令の割り込み応答性、入力キューのデータ競合対策、
  セッションの二重起動ガードなど）を修正した。

### 検証

- 新規統合テスト: UEFI3（Loaded Image / LoadImage→StartImage /
  GOP / イベント / WaitForEvent / LocateHandle / GetTime /
  EBS 無効化）、変数永続化（2 セッション引き継ぎ）、LFN
  （作成・列挙・読み戻し・上書き・削除）、タスクスイッチ +
  SWAPGS 検証カーネル。すべて合格。
- 全回帰テスト（リング / DMA / ロングモード / デバイス /
  Multiboot / BIOS ISO / UEFI サンプル 2 種 / RISC-V / ARM /
  Codable 寛容デコード）合格。全 36 ファイルの文法チェックと
  エンジン + モデルの型チェック合格。
- 実機（iPhone / iPad の Swift Playgrounds）での検証は未実施。

### 既知の制限

- UEFI の通知関数呼び出し、ドライバモデル、Secure Boot、
  ConIn は未提供。一般の OS（Windows / 現在の Linux）は
  まだ起動できない。
- FPU / SSE 命令は未実装（CPUID でも申告しない）。
- GOP のフレームバッファはアプリのコンソールに描画されない。
- 大きな ISO は起動時に全体をメモリへ読み込む。

## [0.9.0] - 2026-11-15

### 追加

- x86 CPU に特権リング（ユーザーモード）を追加した。
  - CPL 管理（セグメントキャッシュの DPL）、TSS の読み込み（LTR）と
    割り込み時の RSP0 スタック切替（32 / 64 ビット両対応）、
    ページウォーク全階層での U/S 検査、CPL に応じた特権命令の
    #GP 検査（CLI / STI / HLT / IN / OUT / LGDT など、IOPL 判定含む）。
- SYSCALL / SYSRET 命令を実装した。STAR / LSTAR / CSTAR /
  SFMASK MSR（0xC0000081〜84）に対応し、リング 3 から
  SYSCALL でリング 0 へ入り、SYSRET で戻れる。
- IDE（ATA）コントローラにバスマスタ DMA を追加した。
  PCI コマンドレジスタの書き込み、BAR4（バスマスタ I/O ベース）、
  PRDT ウォークによる READ DMA / WRITE DMA コマンド（0xC8 / 0xCA 系）、
  完了時の IRQ14 通知、IDENTIFY の DMA 対応ビット。
- UEFI にプロトコルデータベースを追加した。
  InstallProtocolInterface / UninstallProtocolInterface /
  HandleProtocol / OpenProtocol / CloseProtocol /
  ProtocolsPerHandle / LocateHandleBuffer / LocateProtocol /
  InstallConfigurationTable を実動作するようにした。
- UEFI に Block I/O プロトコルを追加した。対象は接続中の
  ディスクイメージ（書き戻しあり）、未接続時は RAM 上の
  FAT12 フロッピーボリューム。Device Path プロトコル
  （PCI ノード + ファイルパス）も公開する。
- FAT ファイルシステムを自作した（`Engine/X86FAT.swift`）。
  FAT12 / 16 / 32 の読み書き、FAT チェーン管理（全 FAT コピーへ
  反映）、ディレクトリ列挙（ロングファイル名の読み取り対応）、
  ファイルの作成・上書き・削除。
- UEFI に Simple File System プロトコルとファイルプロトコルを
  追加した。OpenVolume / Open（読み取り・書き込み・作成）/
  Read / Write / Close / Delete / GetInfo（FileInfo /
  FileSystemInfo / VolumeLabel）/ SetPosition など。
- UEFI ランタイムサービスに変数サービスを追加した。
  GetVariable（容量不足時は必要サイズを返して
  BUFFER_TOO_SMALL）、SetVariable（サイズ 0 で削除）、
  GetNextVariableName、QueryVariableInfo。変数はメモリ上に
  保持する（永続化はしない）。

### 修正

- 64 ビットモードのアキュムレータ即値 ALU 命令（CMP RAX, imm
  など）と TEST RAX, imm が即値を 64 ビットで読んでいた不具合を
  修正した。仕様どおり符号拡張 32 ビット即値として読む
  （v0.8.0 以前に潜在していた問題）。

### 検証

- リング検証カーネル（Multiboot）: プロテクトモード → ロング
  モード移行、リング 3 での SYSCALL / SYSRET 往復、リング 3 の
  CLI による #GP、スーパーバイザページへのリング 3 アクセス
  による #PF、TSS スタック切替を伴うタイマ割り込み、すべて成功。
- DMA 検証カーネル: PCI 設定（BAR4 / コマンドレジスタ）、
  DMA 読み取り（パターン一致 + IRQ14）、DMA 書き込み後の
  PIO 読み戻し一致、すべて成功。
- UEFI 統合テストアプリ（新規サンプル）: 変数サービス
  （Set / Get / 小バッファ / GetNextVariableName）、プロトコル
  検索（LocateHandleBuffer / HandleProtocol）、Block I/O
  （ブートセクタ読み取り）、Simple File System
  （ファイル作成・書き込み・読み戻し・ディレクトリ列挙）、
  ExitBootServices まで、すべて成功。
- 回帰テスト: ロングモード検証カーネル、v0.8.0 UEFI サンプル、
  BIOS ブート（El Torito ISO）、Multiboot カーネル、デバイス
  検証カーネル（TIMER / KBD / PCI / IDE / RTC）、RISC-V
  （retasuOS）、ARM（ArmDemoOS）すべて従来どおり動作。
- 全 36 Swift ファイルの文法チェックと、エンジン + モデルの
  型チェックを実施（エラーなし）。

### 既知の制限

- UEFI に Loaded Image プロトコル、グラフィックス出力（GOP）
  などがないため、Windows Boot Manager や GRUB はまだ起動
  できない。一般の OS（Windows / 現在の Linux）は引き続き
  実行できない。
- TSS タスクスイッチ（ハードウェアタスク切替）と SWAPGS は
  未実装。UEFI 変数は永続化しない。FAT の書き込みは 8.3 形式の
  短いファイル名のみ。
- 実機の Swift Playgrounds での動作検証は未実施。

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
