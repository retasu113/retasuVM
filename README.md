# retasuVM

retasuVM は、iPhone と iPad で仮想マシンを管理するための SwiftUI アプリです。
Apple Human Interface Guidelines（HIG）に沿って設計し、Swift Playgrounds でそのまま開けるプロジェクト形式（`.swiftpm`）で配布します。

> **現在の実行エンジンについて**: v0.3.0 の実行エンジンは RISC-V RV32IM ソフトウェア CPU エミュレータです。起動するゲスト OS イメージを VM ごとに選べます（retasuOS / PlayOS / CalcOS）。iOS / iPadOS ではハードウェア仮想化がアプリに提供されないため、Linux や Windows のような一般の OS は実行できません。

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

## 現在の開発状況

- v0.3.0: ゲストイメージを 3 種類に拡充（retasuOS / PlayOS / CalcOS）、CPU に M 拡張（乗除算）と乱数を追加。全 Swift ファイルの文法チェックと、エミュレータ core の実行テストを実施済み。
- v0.2.0: RISC-V RV32I エミュレータとゲスト OS「retasuOS」を実装。
- v0.1.0: 初期リリース。HIG 準拠の管理 UI とシミュレーションエンジンを実装。
- 変更履歴は [CHANGELOG.md](CHANGELOG.md) を参照してください。
- 開発の必須要件（HIG 準拠、GitHub Releases、Swift Playgrounds ZIP 配布など）は [REQUIREMENTS.md](REQUIREMENTS.md) に定義しています。

## 既知の制約

- 実行できるゲストは同梱の 3 イメージのみです。一般の OS（Linux / Windows など）は実行できません。
- エミュレータは固定スペック（RV32IM、メモリ 1 MiB）で、VM の構成値（CPU / メモリ）はまだエミュレータへ反映されません（管理用メタデータ）。
- ゲスト画面はテキストコンソールのみです（グラフィカル表示はありません）。
- VM の設定データは端末内にのみ保存されます（同期機能はありません）。
- 実機の Swift Playgrounds での動作検証は未実施です。
- アプリアイコンはプレースホルダです。

## ライセンス

MIT License — 詳細は [LICENSE](LICENSE) を参照してください。
