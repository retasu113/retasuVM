import Foundation

// usage: h_lzfse <im4p-or-lzfse-file> <out>
// IM4P なら IMG4 で payload を取り出してから LZFSE 展開する。
let args = CommandLine.arguments
guard args.count == 3 else { print("usage: h_lzfse <in> <out>"); exit(2) }
let data = [UInt8](try! Data(contentsOf: URL(fileURLWithPath: args[1])))
let payload: [UInt8]
if let p = try? IMG4.extractPayload(data) {
    print("IM4P type:", p.type, "payload:", p.payload.count)
    payload = p.payload
} else {
    payload = data
}
guard let out = LZFSE.decode(payload) else { print("LZFSE DECODE FAILED"); exit(1) }
try! Data(out).write(to: URL(fileURLWithPath: args[2]))
print("decoded:", out.count)
