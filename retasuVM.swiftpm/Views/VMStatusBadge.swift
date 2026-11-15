import SwiftUI

/// VM の状態表示。
///
/// HIG に従い、色だけに頼らず「シンボル＋ラベル」で状態を表す。
/// VoiceOver ではラベルがそのまま読み上げられる。
struct VMStatusBadge: View {
    let state: VMState

    var body: some View {
        Label(state.label, systemImage: state.systemImage)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint, in: Capsule())
            .accessibilityLabel("状態: \(state.label)")
    }

    private var tint: Color {
        switch state {
        case .stopped: return .gray
        case .running: return .green
        case .paused: return .orange
        case .error: return .red
        }
    }
}
