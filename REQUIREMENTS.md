# retasuVM 開発必須要件

制定: 2026-11-15（ユーザーの指示により追加）
位置づけ: 本書の要件は任意の改善ではなく**必須要件**である。retasuVM のすべての開発・リリースに適用する。

---

## 1. Apple Human Interface Guidelines（HIG）の厳守

- Apple 公式 Human Interface Guidelines を必ず参照すること。
  公式: https://developer.apple.com/design/human-interface-guidelines/
- retasuVM のすべての UI・UX 設計に Apple HIG を適用する。
- 各画面の実装後に HIG 準拠チェックを実施する。

### デザイン原則

- Apple 純正アプリに近い自然な操作感
- ネイティブ SwiftUI を優先
- 過剰な装飾を避ける
- 一貫性のあるナビゲーション
- 明確な視覚的階層
- 適切な余白
- 標準的な操作体系
- システム標準コンポーネントの積極的な利用
- ダークモード・ライトモードへの対応
- Dynamic Type 対応
- VoiceOver 対応
- Reduce Motion 対応
- 十分なコントラスト
- 適切なタップ領域

### iPhone 対応

- iPhone の画面サイズに適応
- Safe Area を正しく処理
- 標準的な Tab Bar や NavigationStack を使用
- 片手操作を考慮
- キーボード表示時のレイアウト崩れを防止
- 縦横画面に対応

### iPad 対応

- NavigationSplitView などを活用
- サイドバーを利用した VM 管理
- 複数カラムレイアウト
- 外部キーボード対応
- マウス・トラックパッド対応
- iPad の大画面を有効活用
- マルチタスク環境での表示を考慮

### 仮想マシン操作 UI

- VM の起動・停止・再起動などは、操作内容が明確に分かるデザインにする。
- 破壊的操作には確認画面を設ける。
- 実行中・停止中・一時停止中・エラーなどの状態を、色だけに頼らず表示する。

### デザイン品質

- Apple の純正アプリや UTM の操作性を参考にする。
- ただし、Apple のロゴや純正アプリのブランド表現を無断で模倣しない。
- 見た目だけでなく、操作性・アクセシビリティ・一貫性を重視する。

---

## 2. GitHub Release の自動作成

- 開発が進み、安定したバージョンが完成したら GitHub Releases を作成する。
- バージョン形式: Semantic Versioning（例: v0.1.0 / v0.2.0 / v0.5.0 / v1.0.0）
- 各 Release には以下を含める:
  - バージョン番号
  - リリースタイトル
  - リリースノート
  - 新機能
  - 修正内容
  - 既知の問題
  - 動作確認環境
- リリースは正式リリースとして公開する（2026-11-15 のユーザー指示により、以後は Pre-release にしない）。
- **ソースコード変更時の GitHub 同期（必須・2026-11-26 ユーザー指示）**: ソースコード（アプリ本体、ハーネス/テスト、自作リストアスクリプトを含む）を変更したら、その都度 GitHub（retasu113/retasuVM）へアップロードし、リモート側で反映を検証するまでを完了条件とする。リリース時のみの同期では不十分。

---

## 3. Swift Playgrounds プロジェクトの ZIP 配布（最重要要件）

- GitHub Release を作成するたびに、Swift Playgrounds で直接開ける retasuVM プロジェクト一式を ZIP 形式にし、同じ Release の Assets に**必ず**添付する。
- ZIP のファイル名: `retasuVM-vX.X.X-SwiftPlaygrounds.zip`（例: `retasuVM-v1.0.0-SwiftPlaygrounds.zip`）

### ZIP に含めるもの

- retasuVM.swiftpm または正しい Swift Playgrounds 対応プロジェクト形式
- すべての Swift ソースコード
- SwiftUI 関連ファイル
- 必要なリソース
- Assets.xcassets
- 必要な設定ファイル
- README.md
- LICENSE
- BUILD.md
- CHANGELOG.md

### 要件

- 実際のプロジェクト構造を確認し、Swift Playgrounds で開ける正しい形式で ZIP を作成する。単にソースコードを ZIP にまとめるだけでは不十分。
- ZIP 作成前に、Swift Playgrounds のプロジェクトファイル（.swiftpm）の正しい構成・作り方をインターネット（Apple 公式ドキュメント等）で調査し、その結果に基づいて作成する（2026-11-16 ユーザー指示）。単なるソースの寄せ集めにしない。
- ZIP をダウンロードして、iPad または iPhone の Swift Playgrounds から開ける状態にする。
- 不要なファイルは含めない。

### ZIP に含めないもの

- .git
- DerivedData
- ビルドキャッシュ
- 一時ファイル
- 秘密鍵
- アクセストークン
- 個人情報
- OS イメージ
- 大容量のテスト用データ

---

## 4. ZIP の検証

GitHub Release にアップロードする前に、必ず以下を検証する。

1. ZIP が正常に展開できる。
2. プロジェクトのファイル構成が正しい。
3. Swift Playgrounds 対応形式になっている。
4. 必要な Swift ファイルがすべて含まれている。
5. リソース参照が壊れていない。
6. 不要な秘密情報が含まれていない。
7. README の手順と実際の構成が一致している。

- 利用可能な Xcode 環境があればビルド・テストを行う。
- 実機 Swift Playgrounds での検証ができない場合は、その旨を Release Notes に明記する。
- リリース前の全体バグチェックでは、対象ファイルを **1ファイルにつき3回** チェックする（2026-11-16 ユーザー指示）。バグチェック自体を省略しない。
- バグチェックを行うときは、毎回その前に Swift のコードの書き方（言語仕様・書き方・慣習）をインターネットで調べてから行う（2026-11-16 ユーザー指示）。
- リリースは OS の起動達成ごとに行う（2026-11-16 ユーザー指示）: Sequoia 15.6.1 の完全起動で v0.16.0、続いて Tahoe 26.6.2 が起動できたらその時点で、Golden Gate（macOS 27.2）が起動できたらその時点で、それぞれ同じ手順（テスト→全ファイル3回バグチェック→.swiftpm 構成の事前調査に基づく ZIP 作成→SHA-256 検証→正式リリース）で公開する。

---

## 5. Release Assets の構成

各 GitHub Release には以下を添付する。

### 必須

- `retasuVM-vX.X.X-SwiftPlaygrounds.zip`
- `SHA256SUMS.txt`

### 任意

- ソースコードの追加パッケージ
- テストレポート
- スクリーンショット

- ZIP の SHA-256 ハッシュを計算し、SHA256SUMS.txt に記録する。
- GitHub の自動生成 Source Code ZIP と、Swift Playgrounds 用 ZIP を混同しない。

---

## 6. 自動化

- 可能なら GitHub Actions を利用する。
- Release 作成時に以下を実行する:
  1. ソースコードを取得
  2. プロジェクト構造を検証
  3. テストを実行
  4. Swift Playgrounds 用 ZIP を作成
  5. ZIP の整合性を検証
  6. SHA-256 を計算
  7. GitHub Release Assets へアップロード
- iOS 実機環境が必要なテストを GitHub Actions だけで実行できると誤認しない。
- 利用可能な Runner に応じて適切な検証を実施する。
- GitHub Actions で実現できない部分は、ローカルビルド手順を用意する。

---

## 7. README の更新

README.md には必ず以下を記載する。

- retasuVM の概要
- 主な機能
- 対応プラットフォーム
- Swift Playgrounds での導入方法
- GitHub Releases から ZIP を取得する方法
- ZIP を Swift Playgrounds で開く方法
- 現在の開発状況
- 既知の制約
- ライセンス

---

## 8. 完成条件

以下をすべて満たすこと。

- [ ] Apple HIG を考慮した UI になっている。
- [ ] iPhone・iPad の両方に最適化されている。
- [ ] GitHub リポジトリが Public で公開されている。
- [ ] バージョン管理が行われている。
- [ ] GitHub Release が作成されている。
- [ ] Swift Playgrounds 用 ZIP が Release Assets に添付されている。
- [ ] ZIP の整合性が検証されている。
- [ ] SHA-256 が提供されている。
- [ ] README に導入方法が記載されている。
