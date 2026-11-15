# BUILD — ビルドと配布の手順

## 必要な環境

- Swift Playgrounds 4 以降（iPad / iPhone / Mac）、または Xcode 15 以降
- iOS 17 / iPadOS 17 以降

## ローカルで開く・実行する

### Swift Playgrounds

1. `retasuVM.swiftpm` を Swift Playgrounds で開く。
2. 実行ボタン（▶）を押すとアプリが起動する。

### Xcode

1. `retasuVM.swiftpm` を Xcode で開く（File > Open）。
2. 実行先に iPhone / iPad（実機またはシミュレータ）を選んで Run。

## プロジェクト構成

```
retasuVM.swiftpm/
├── Package.swift          … Swift Playgrounds 用パッケージ定義
├── RetasuVMApp.swift      … @main エントリポイント
├── ContentView.swift      … 画面幅に応じたルートレイアウト
├── Models/
│   ├── VirtualMachine.swift … VM・構成・状態のモデル
│   └── VMStore.swift          … 一覧管理・状態遷移・永続化
├── Engine/
│   ├── GuestSession.swift     … セッション共通インターフェース
│   ├── RISCVCPU.swift         … RISC-V RV32IM CPU エミュレータ
│   ├── RISCVAssembler.swift   … RISC-V ゲスト用アセンブラ
│   ├── GuestRuntime.swift     … RISC-V ゲスト共通ランタイム（_start と基本ルーチン）
│   ├── RetasuOS.swift         … ゲスト OS「retasuOS」（対話型モニタ）
│   ├── PlayOS.swift           … ゲスト OS「PlayOS」（数当てゲーム・サイコロ）
│   ├── CalcOS.swift           … ゲスト OS「CalcOS」（RPN 計算機）
│   ├── GuestImage.swift       … 起動イメージの定義と選択
│   ├── ISO9660.swift          … ISO 9660 パーサ（BOOT.BIN の取り出し）
│   ├── IsoDemoOS.swift        … ISO ブート確認用ゲスト（サンプル ISO に収録）
│   ├── GuestOS.swift          … 旧ファイル名の名残（空。RetasuOS.swift に改名済み）
│   ├── VMEngine.swift         … EmulatorSession（RISC-V 実行セッション管理）
│   ├── X86CPU.swift           … x86 リアルモード CPU エミュレータ
│   ├── X86BIOS.swift          … x86 BIOS サービス層とブート処理
│   ├── ElTorito.swift         … El Torito ブート拡張パーサ（x86 ISO ブート）
│   ├── X86Session.swift       … x86 実行セッション
│   ├── ARMCPU.swift           … ARM (ARMv7-A / A32 サブセット) CPU エミュレータ
│   ├── ARMAssembler.swift     … ARM ゲスト用アセンブラ
│   ├── ARMDemoOS.swift        … ARM デモゲスト「ArmDemoOS」
│   └── ARMSession.swift       … ARM 実行セッション
├── Views/
│   ├── VMListView.swift       … 一覧
│   ├── VMDetailView.swift     … 詳細・操作
│   ├── VMEditorView.swift     … 作成・編集フォーム
│   ├── VMConsoleView.swift    … コンソール
│   ├── VMStatusBadge.swift    … 状態バッジ
│   └── SettingsView.swift     … 設定・情報
└── Assets.xcassets/           … アイコン（プレースホルダ）・アクセントカラー
```

## リリース手順

バージョンは Semantic Versioning（例: `v0.1.0`）に従います。
タグ `vX.X.X` を push すると GitHub Actions（`.github/workflows/release.yml`）が
Swift Playgrounds 用 ZIP と SHA-256 を作成し、Release へ添付します。
手動で行う場合は以下の手順を使います。

### Swift Playgrounds 用 ZIP の作成

```sh
VERSION=0.1.0
mkdir -p dist/stage
cp -R retasuVM.swiftpm dist/stage/
cp README.md LICENSE BUILD.md CHANGELOG.md dist/stage/
cd dist/stage
zip -r ../retasuVM-v${VERSION}-SwiftPlaygrounds.zip retasuVM.swiftpm README.md LICENSE BUILD.md CHANGELOG.md
cd ..
shasum -a 256 retasuVM-v${VERSION}-SwiftPlaygrounds.zip > SHA256SUMS.txt
```

ZIP に含めないもの: `.git`、DerivedData、ビルドキャッシュ、一時ファイル、
秘密鍵・アクセストークン・個人情報、OS イメージ、大容量のテスト用データ。

### ZIP の検証（アップロード前必須）

1. ZIP が正常に展開できる（`unzip -t` でエラーなし）。
2. プロジェクトのファイル構成が正しい（`retasuVM.swiftpm/Package.swift` が存在）。
3. Swift Playgrounds 対応形式になっている（`.swiftpm` フォルダ構成）。
4. 必要な Swift ファイルがすべて含まれている。
5. リソース参照が壊れていない（Assets.xcassets の JSON が正しい）。
6. 不要な秘密情報が含まれていない。
7. README の手順と実際の構成が一致している。

Xcode 環境がある場合はビルド確認を行います。
実機 Swift Playgrounds での検証ができない場合は、その旨を Release Notes に明記します。

### Release Notes に含めるもの

- バージョン番号とリリースタイトル
- 新機能 / 修正内容 / 既知の問題
- 動作確認環境（検証した OS・機種・Swift Playgrounds のバージョン、または未検証である旨）

開発版は Pre-release として公開し、安定版と区別します。
