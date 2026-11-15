# retasuVM

retasuVM は、iPhone と iPad で仮想マシンを管理するための SwiftUI アプリです。
Apple Human Interface Guidelines（HIG）に沿って設計し、Swift Playgrounds でそのまま開けるプロジェクト形式（`.swiftpm`）で配布します。

> **現在の実行エンジンについて**: v0.6.0 の実行エンジンは、すべて自作のソフトウェア CPU エミュレータ 3 種類です。RISC-V（RV32IM）、x86（リアルモード + 32 ビット プロテクトモード + 自作 BIOS）、ARM（ARMv7-A サブセット）を VM ごとに選べます。x86 は El Torito 対応 ISO から BIOS ブートできるほか、Multiboot 対応カーネル（ELF32）をプロテクトモードで直接起動できます。iOS / iPadOS ではハードウェア仮想化がアプリに提供されないため、Windows や現在の Linux のような一般の OS は実行できません（ブート方式と周辺デバイスの再現が別途必要です）。

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
- x86 エミュレータ（リアルモード + 32 ビット プロテクトモード CPU + 自作 BIOS サービス）
  - El Torito 対応 ISO から BIOS ブート（フロッピー / ハードディスク エミュレーション）
  - ブートセクタ付き raw イメージ（.img）からもブート可能
  - BIOS コール対応: INT 10h（画面）/ INT 13h（ディスク、CHS・LBA）/ INT 16h（キーボード）/ INT 12h / INT 1Ah / INT 15h
  - 32 ビット プロテクトモード対応（GDT / LDT、IDT 割り込み・例外配送、ページング、CPUID）
  - Multiboot ブートローダ内蔵: Multiboot 対応 ELF32 カーネルを直接起動（ISO 内の KERNEL.ELF も自動検出）
  - シリアルポート（COM1）もコンソールに接続
- ARM エミュレータ（ARMv7-A、A32 命令サブセット + 自作アセンブラ）
  - デモゲスト「ArmDemoOS」（help / fact / echo / quit）
- 対話型コンソール画面（コマンド入力・イメージ連動のクイックコマンド・リアルタイム出力）
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

x86 で起動できるのは、El Torito 対応 ISO（フロッピー / ハードディスク エミュレーション、エミュレーションなし）と、ブートセクタ（55 AA）付きの raw イメージです。ゲストは 16 ビット リアルモードで動作し、BIOS コール（INT 10h / 13h / 16h など）とシリアルポート（COM1）が使えます。ブートセクタから GDT を設定して 32 ビット プロテクトモードへ移行する OS も動作します（ページング、IDT 割り込み対応）。Windows や現在の Linux は、ブート方式と周辺デバイスの再現が別途必要なため起動できません。

### x86（Multiboot カーネル）

1. Release から `retasuVM-sample-kernel.elf`（試作用サンプル）をダウンロードします。
2. アプリで VM を作成（または編集）し、CPU アーキテクチャを「x86」にして、ダウンロードした .elf を選びます。
3. VM を起動すると、内蔵 Multiboot ローダがカーネルを読み込み、プロテクトモードで起動します。サンプルカーネルはメモリ情報を表示し、自らページングを有効化して停止します。

自作カーネルの条件: Multiboot（バージョン 1）ヘッダを持つ ELF32（i386）カーネル。ISO のルートに `KERNEL.ELF` という名前で置いた場合も自動で検出します。エントリ時点の状態は Multiboot 仕様どおり（プロテクトモード、フラットセグメント、EAX = 0x2BADB002、EBX = 情報構造体）です。

## 現在の開発状況

- v0.6.0: x86 に 32 ビット プロテクトモード（GDT / IDT / ページング）と Multiboot ブートローダを追加。Multiboot 対応カーネルが起動できるようになった。サンプルカーネルと、全エンジンの実行テストを実施済み。
- v0.5.0: x86（リアルモード CPU + 自作 BIOS + El Torito ブート）と ARM（ARMv7-A サブセット + 自作アセンブラ + ArmDemoOS）の 2 エンジンを追加。アーキテクチャは VM ごとに選択可能。全 Swift ファイルの文法チェックと、3 エンジンすべての実行テストを実施済み。
- v0.4.0: ISO 9660 イメージからの起動に対応（BOOT.BIN 形式）。サンプル ISO と IsoDemoOS を同梱。全 Swift ファイルの文法チェックと、ISO ブートを含む実行テストを実施済み。
- v0.3.0: ゲストイメージを 3 種類に拡充（retasuOS / PlayOS / CalcOS）、CPU に M 拡張（乗除算）と乱数を追加。
- v0.2.0: RISC-V RV32I エミュレータとゲスト OS「retasuOS」を実装。
- v0.1.0: 初期リリース。HIG 準拠の管理 UI とシミュレーションエンジンを実装。
- 変更履歴は [CHANGELOG.md](CHANGELOG.md) を参照してください。
- 開発の必須要件（HIG 準拠、GitHub Releases、Swift Playgrounds ZIP 配布など）は [REQUIREMENTS.md](REQUIREMENTS.md) に定義しています。

## 既知の制約

- 実行できるゲストは、同梱イメージ（RISC-V 3 種 + ArmDemoOS）、retasuVM 形式の ISO（BOOT.BIN 入り）、x86 のリアルモード / プロテクトモード ブートプログラム（El Torito ISO / raw イメージ）、Multiboot 対応カーネル（ELF32）です。一般の OS（Windows / 現在の Linux など）や、そのインストール ISO は実行できません（ブート方式と周辺デバイスのエミュレーションが別途必要なため）。
- x86 のプロテクトモードはリング 0 のみで、タスクスイッチとユーザーモード、UEFI は未実装です（ファームウェア相当は自作 BIOS サービス層が担います）。ARM エンジンは命令サブセットのみで、MMU や実機向け OS のブートには対応しません。
- エミュレータは固定スペック（RISC-V: RV32IM / 1 MiB、x86: リアルモード / 16 MiB、ARM: ARMv7-A サブセット / 4 MiB）で、VM の構成値（CPU / メモリ）はまだエミュレータへ反映されません（管理用メタデータ）。
- ゲスト画面はテキストコンソールのみです（グラフィカル表示はありません）。
- VM の設定データは端末内にのみ保存されます（同期機能はありません）。
- 実機の Swift Playgrounds での動作検証は未実施です。
- アプリアイコンはプレースホルダです。

## ライセンス

MIT License — 詳細は [LICENSE](LICENSE) を参照してください。
