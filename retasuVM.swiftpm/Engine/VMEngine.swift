import Foundation

/// 仮想マシンの実行バックエンドが満たすべきインターフェース。
///
/// 現在の実装は `SimulatedVMEngine`（画面遷移と状態管理を確認するための
/// シミュレーション）であり、実際の仮想化は行わない。
/// 将来、実バックエンドに差し替える場合はこのプロトコルに適合させる。
protocol VMEngine {
    func start(_ vm: VirtualMachine) async throws -> [String]
    func stop(_ vm: VirtualMachine) async throws -> [String]
    func pause(_ vm: VirtualMachine) async throws -> [String]
    func resume(_ vm: VirtualMachine) async throws -> [String]
}

/// シミュレーション用エンジン。
///
/// 起動・停止などの各操作で、コンソールに表示するログ行を返す。
/// 遅延はごく短くし、操作の応答性を損なわないようにしている。
struct SimulatedVMEngine: VMEngine {
    func start(_ vm: VirtualMachine) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(600))
        return [
            "[retasuVM] \(vm.name) を起動しています…",
            "[retasuVM] CPU \(vm.configuration.cpuCount) コア / メモリ \(vm.configuration.memoryText) を割り当てました",
            "[retasuVM] ゲスト OS（\(vm.configuration.guestOS.label)）のブートを開始しました",
            "[retasuVM] 起動が完了しました（シミュレーション）"
        ]
    }

    func stop(_ vm: VirtualMachine) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(400))
        return [
            "[retasuVM] \(vm.name) にシャットダウンを要求しました",
            "[retasuVM] 停止しました"
        ]
    }

    func pause(_ vm: VirtualMachine) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(300))
        return ["[retasuVM] \(vm.name) を一時停止しました"]
    }

    func resume(_ vm: VirtualMachine) async throws -> [String] {
        try await Task.sleep(for: .milliseconds(300))
        return ["[retasuVM] \(vm.name) を再開しました"]
    }
}
