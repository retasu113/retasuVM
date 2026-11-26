import Foundation

/// ゲスト実行セッションの共通インターフェース。
///
/// RISC-V（`EmulatorSession`）、x86（`X86Session`）、ARM（`ARMSession`）の
/// 各セッションが準拠し、`VMStore` はこの型越しに操作する。
/// コールバックはメインスレッド以外から呼ばれることがあるため、
/// 受け側（VMStore）がメインアクターへ移す。
protocol GuestSession: AnyObject {
    /// ゲストのコンソール出力（まとめて通知される）
    var onOutput: ((String) -> Void)? { get set }
    /// コンソール消去の要求
    var onClear: (() -> Void)? { get set }
    /// ゲストが正常に停止した（引数は終了コード）
    var onHalt: ((Int32) -> Void)? { get set }
    /// ゲストがエラーで停止した（引数はメッセージ）
    var onFault: ((String) -> Void)? { get set }

    func setPaused(_ paused: Bool)
    func terminate()
    func sendInput(_ text: String)
}
