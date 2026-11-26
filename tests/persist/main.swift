import Foundation

// UEFI 変数永続化テスト: セッション1で SetVariable → 変数を回収 →
// セッション2へ引き継いで GetVariable で読み戻す。
func runSession(image: [UInt8], initial: [X86UEFI.Variable]) -> (output: String, variables: [X86UEFI.Variable]) {
    let session = X86Session()
    session.initialUEFIVariables = initial
    var output = ""
    let semaphore = DispatchSemaphore(value: 0)
    session.onOutput = { output += $0 }
    session.onHalt = { _ in semaphore.signal() }
    session.onFault = { message in output += "FAULT: \(message)"; semaphore.signal() }
    try! session.boot(imageData: image)
    _ = semaphore.wait(timeout: .now() + 20)
    session.terminate()
    return (output, session.uefiVariables)
}

let setImage = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let getImage = [UInt8](try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])))
let first = runSession(image: setImage, initial: [])
print("session1: \(first.output.trimmingCharacters(in: .whitespacesAndNewlines))")
print("harvested variables: \(first.variables.count)")
let second = runSession(image: getImage, initial: first.variables)
print("session2: \(second.output.trimmingCharacters(in: .whitespacesAndNewlines))")
