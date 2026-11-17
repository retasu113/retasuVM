import SwiftUI
import UniformTypeIdentifiers

/// 仮想マシンの新規作成・編集フォーム。
///
/// 標準の `Form` を使い、キーボード表示時もレイアウトが崩れない構成にする。
/// 名前が空の場合は保存できないようバリデーションする。
/// CPU アーキテクチャを選び、RISC-V では起動方法（ゲストイメージ / ISO）、
/// x86 では BIOS ブート用イメージ、ARM では固定のデモゲストになる。
struct VMEditorView: View {
    @EnvironmentObject private var store: VMStore
    @Environment(\.dismiss) private var dismiss

    /// 編集対象。nil の場合は新規作成。
    let editing: VirtualMachine?

    @State private var name: String
    @State private var architecture: CPUArchitecture
    @State private var guestImage: GuestImage
    @State private var useISO: Bool
    @State private var isoFileName: String?
    /// この編集セッション中に取り込んだ ISO のファイル名。
    /// キャンセルや差し替えで未使用になった場合に片付けるために保持する。
    @State private var importedFileName: String?
    @State private var isoDisplayName: String?
    /// 内蔵サンプルから起動するか（ファイルより優先）
    @State private var useSample: Bool
    /// 選択中の内蔵サンプル
    @State private var sampleSelection: BuiltInSample
    /// ARM64 のブート方式
    @State private var arm64Platform: Arm64Platform
    @State private var cpuCount: Int
    @State private var memoryMB: Int
    @State private var diskGB: Int
    @State private var networkEnabled: Bool
    @State private var sharedFolderEnabled: Bool

    @State private var showingISOImporter = false
    @State private var importError: String?
    @State private var showingImportError = false

    init(editing: VirtualMachine?) {
        self.editing = editing
        let config = editing?.configuration ?? VMConfiguration()
        _name = State(initialValue: editing?.name ?? "")
        _architecture = State(initialValue: config.architecture)
        _guestImage = State(initialValue: config.guestImage)
        _useISO = State(initialValue: config.useISO)
        _isoFileName = State(initialValue: config.isoFileName)
        _isoDisplayName = State(initialValue: config.isoDisplayName)
        _useSample = State(initialValue: config.builtInSample != nil)
        _sampleSelection = State(initialValue: config.builtInSample ?? .kernel)
        _arm64Platform = State(initialValue: config.arm64Platform)
        _cpuCount = State(initialValue: config.cpuCount)
        _memoryMB = State(initialValue: config.memoryMB)
        _diskGB = State(initialValue: config.diskGB)
        _networkEnabled = State(initialValue: config.networkEnabled)
        _sharedFolderEnabled = State(initialValue: config.sharedFolderEnabled)
    }

    /// ISO / イメージファイルが必須かどうか（RISC-V の ISO 起動と x86。
    /// 内蔵サンプル使用時はファイル不要）
    private var needsImageFile: Bool {
        !useSample && (architecture == .x86 || (architecture == .riscv && useISO))
    }

    private var isValid: Bool {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        if needsImageFile && isoFileName == nil { return false }
        return true
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("名前", text: $name)
                        .textInputAutocapitalization(.never)
                    Picker("CPU アーキテクチャ", selection: $architecture) {
                        ForEach(CPUArchitecture.allCases) { architecture in
                            Label(architecture.label, systemImage: architecture.systemImage)
                                .tag(architecture)
                        }
                    }
                    switch architecture {
                    case .riscv:
                        Picker("起動方法", selection: $useISO) {
                            Text("ゲストイメージ").tag(false)
                            Text("ISO ファイル").tag(true)
                        }
                        if useISO {
                            imageSourceRows(sampleButtonTitle: "ISO ファイルを選ぶ")
                        } else {
                            Picker("ゲストイメージ", selection: $guestImage) {
                                ForEach(GuestImage.allCases) { image in
                                    Label(image.displayName, systemImage: image.systemImage)
                                        .tag(image)
                                }
                            }
                        }
                    case .x86:
                        imageSourceRows(sampleButtonTitle: "ISO / イメージファイルを選ぶ")
                    case .arm:
                        LabeledContent("ゲスト", value: "ArmDemoOS")
                    case .arm64:
                        Picker("ブート方式", selection: $arm64Platform) {
                            ForEach(Arm64Platform.allCases) { platform in
                                Text(platform.label).tag(platform)
                            }
                        }
                        LabeledContent("ゲスト", value: arm64Platform == .mac ? "MacBootTestOS" : "Arm64DemoOS")
                    }
                } header: {
                    Text("基本情報")
                } footer: {
                    Text(footerText)
                }

                Section("ハードウェア") {
                    Stepper(value: $cpuCount, in: 1...16) {
                        LabeledContent("CPU", value: "\(cpuCount) コア")
                    }
                    Stepper(value: $memoryMB, in: 1...32768, step: 256) {
                        LabeledContent("メモリ", value: memoryText)
                    }
                    Stepper(value: $diskGB, in: 1...512, step: 1) {
                        LabeledContent("ディスク", value: "\(diskGB) GB")
                    }
                }

                Section("オプション") {
                    Toggle("ネットワーク", isOn: $networkEnabled)
                    Toggle("共有フォルダ", isOn: $sharedFolderEnabled)
                }

                if !isValid {
                    Section {
                        Label(validationMessage, systemImage: "exclamationmark.circle")
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    }
                }
            }
            .onChange(of: architecture) { _, newArchitecture in
                // アーキテクチャを変えたら、サンプル選択をそのアーキテクチャのものへ合わせる
                if sampleSelection.architecture != newArchitecture {
                    sampleSelection = BuiltInSample.samples(for: newArchitecture).first ?? .kernel
                }
            }
            .onChange(of: useSample) { _, _ in syncSampleSelection() }
            .onChange(of: useISO) { _, _ in syncSampleSelection() }
            .fileImporter(
                isPresented: $showingISOImporter,
                allowedContentTypes: [
                    UTType(filenameExtension: "iso") ?? .data,
                    UTType(filenameExtension: "img") ?? .data,
                    UTType(filenameExtension: "efi") ?? .data,
                    .data,
                ]
            ) { result in
                handleISOImport(result)
            }
            .alert("ファイルを読み込めませんでした", isPresented: $showingImportError) {
                Button("OK") {}
            } message: {
                Text(importError ?? "")
            }
            .navigationTitle(editing == nil ? "仮想マシンを追加" : "仮想マシンを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { cancelEditing() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!isValid)
                }
            }
        }
    }

    /// 選択中イメージの表示とファイル選択ボタン（ISO 起動で共通）。
    @ViewBuilder
    private func isoPickerRows(buttonTitle: String) -> some View {
        LabeledContent("イメージ", value: isoDisplayName ?? "未選択")
        Button {
            showingISOImporter = true
        } label: {
            Label(buttonTitle, systemImage: "opticaldisc")
        }
    }

    /// イメージの入手方法（ファイル / 内蔵サンプル）の選択行。
    @ViewBuilder
    private func imageSourceRows(sampleButtonTitle: String) -> some View {
        Picker("イメージの場所", selection: $useSample) {
            Text("ファイル").tag(false)
            Text("内蔵サンプル").tag(true)
        }
        if useSample {
            Picker("サンプル", selection: $sampleSelection) {
                ForEach(BuiltInSample.samples(for: architecture)) { sample in
                    Label(sample.displayName, systemImage: sample.systemImage)
                        .tag(sample)
                }
            }
            Text(sampleSelection.detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            isoPickerRows(buttonTitle: sampleButtonTitle)
        }
    }

    private var footerText: String {
        switch architecture {
        case .riscv:
            if useISO {
                return "ISO 9660 イメージのルート直下にある BOOT.BIN（RISC-V フラットバイナリ）を起動します。内蔵サンプル ISO も選べます。"
            }
            return "ゲストイメージは、起動時にエミュレータへ読み込む OS です。\(guestImage.displayName): \(guestImage.detail)"
        case .x86:
            return "内蔵 BIOS が El Torito 対応 ISO（またはブートセクタ付き raw イメージ）からブートセクタを読み込んで実行します。Multiboot 対応カーネル（ELF32 ファイル、または ISO 内の KERNEL.ELF）は 32 ビット プロテクトモードで直接起動でき、64 ビット ロングモードへの移行も可能です。UEFI アプリケーション（.efi、PE32+ / x86-64）は最小 UEFI ファームウェアで起動します。割り込みコントローラ（PIC / APIC）、タイマ（PIT）、PCI、IDE ディスク、キーボード、RTC、ACPI テーブルなどの周辺デバイスも再現しています。試作用のサンプルはアプリに内蔵されています。"
        case .arm:
            return "ARMv7-A エミュレータ上で、内蔵のデモゲスト「ArmDemoOS」が動きます（fact で 12! の計算、echo、help が使えます）。"
        case .arm64:
            return "AArch64 エミュレータ（EL0 / EL1 + MMU）上で、内蔵のデモゲスト「Arm64DemoOS」が動きます。Apple Silicon Mac のエミュレーション（Henge 方式）の基盤です。"
        }
    }

    private var validationMessage: String {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "名前を入力してください"
        }
        return "イメージファイルを選んでください"
    }

    private var memoryText: String {
        VMConfiguration(cpuCount: cpuCount, memoryMB: memoryMB, diskGB: diskGB).memoryText
    }

    private func handleISOImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            do {
                // 元の VM が参照する ISO の削除は保存時に行う（キャンセル時に
                // 元の VM が参照するファイルを消してしまわないため）。
                // ただし、このセッションで取り込んだ前回のファイルは
                // 差し替え時点で未使用になるため、ここで片付ける。
                let newFileName = try store.importISO(from: url, architecture: architecture)
                if let previous = importedFileName,
                   previous != editing?.configuration.isoFileName {
                    store.deleteISOFile(named: previous)
                }
                isoFileName = newFileName
                importedFileName = newFileName
                isoDisplayName = url.lastPathComponent
            } catch {
                importError = error.localizedDescription
                showingImportError = true
            }
        case .failure(let error):
            importError = error.localizedDescription
            showingImportError = true
        }
    }

    /// サンプル選択が現在のアーキテクチャの候補に含まれていなければ先頭へ合わせる。
    /// アーキテクチャが変わらない経路（新規作成で最初から RISC-V 等）でも
    /// 候補外の選択（既定値の .kernel）が残らないようにするための同期。
    private func syncSampleSelection() {
        let candidates = BuiltInSample.samples(for: architecture)
        if !candidates.contains(sampleSelection), let first = candidates.first {
            sampleSelection = first
        }
    }

    private func save() {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveUseISO = architecture == .x86 ? true : useISO
        // 候補外のサンプル選択が残っていたら現在のアーキテクチャの候補へ寄せる
        let candidates = BuiltInSample.samples(for: architecture)
        let effectiveSample = candidates.contains(sampleSelection) ? sampleSelection : candidates.first
        // 内蔵サンプル使用時はファイル参照を外す（旧ファイルは後段で片付ける）
        let sampleApplies = useSample && effectiveSample != nil
            && (architecture == .x86 || (architecture == .riscv && useISO))
        let effectiveBuiltInSample: BuiltInSample? = sampleApplies ? effectiveSample : nil
        let effectiveISOFileName: String?
        let effectiveISODisplayName: String?
        if sampleApplies {
            effectiveISOFileName = nil
            effectiveISODisplayName = nil
        } else {
            switch architecture {
            case .riscv:
                effectiveISOFileName = useISO ? isoFileName : editing?.configuration.isoFileName
                effectiveISODisplayName = useISO ? isoDisplayName : editing?.configuration.isoDisplayName
            case .x86:
                effectiveISOFileName = isoFileName
                effectiveISODisplayName = isoDisplayName
            case .arm, .arm64:
                effectiveISOFileName = editing?.configuration.isoFileName
                effectiveISODisplayName = editing?.configuration.isoDisplayName
            }
        }
        let configuration = VMConfiguration(
            cpuCount: cpuCount,
            memoryMB: memoryMB,
            diskGB: diskGB,
            architecture: architecture,
            guestOS: editing?.configuration.guestOS ?? .linux,
            guestImage: guestImage,
            useISO: effectiveUseISO,
            isoFileName: effectiveISOFileName,
            isoDisplayName: effectiveISODisplayName,
            builtInSample: effectiveBuiltInSample,
            arm64Platform: architecture == .arm64 ? arm64Platform : (editing?.configuration.arm64Platform ?? .demo),
            networkEnabled: networkEnabled,
            sharedFolderEnabled: sharedFolderEnabled,
            uefiVariables: editing?.configuration.uefiVariables ?? []
        )
        if let editing {
            store.update(editing, name: trimmedName, configuration: configuration)
            // ISO を差し替えた場合は、元の保存ファイルを片付ける。
            // ただし更新が実際に反映された場合のみ（実行中などで update が
            // 適用されなかった場合、保存済み構成がまだ旧ファイルを参照する）
            if let oldFileName = editing.configuration.isoFileName,
               oldFileName != configuration.isoFileName,
               store.machine(id: editing.id)?.configuration.isoFileName == configuration.isoFileName {
                store.deleteISOFile(named: oldFileName)
            }
        } else {
            store.add(name: trimmedName, configuration: configuration)
        }
        // 取り込んだのに最終構成が参照しないファイル（アーキテクチャ変更等）は片付ける
        if let importedFileName, importedFileName != configuration.isoFileName {
            store.deleteISOFile(named: importedFileName)
        }
        dismiss()
    }

    /// キャンセル時の後片付け。取り込んだファイルが元の VM のものを
    /// 指していない限り、未使用の取り込みファイルを削除してから閉じる。
    private func cancelEditing() {
        if let importedFileName, importedFileName != editing?.configuration.isoFileName {
            store.deleteISOFile(named: importedFileName)
        }
        dismiss()
    }
}
