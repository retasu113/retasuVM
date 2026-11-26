import Foundation

// ARM64Assembler の出力ワードを 16 進で 1 行 1 ワードで出す。
// clang が組んだ corpus.o の .text と突き合わせるためのハーネス。
let source = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
var assembler = ARM64Assembler()
let program = try assembler.assemble(source)
let bytes = program.bytes
for i in stride(from: 0, to: bytes.count, by: 4) {
    let word = UInt32(bytes[i]) | (UInt32(bytes[i + 1]) << 8) | (UInt32(bytes[i + 2]) << 16) | (UInt32(bytes[i + 3]) << 24)
    print(String(format: "%08x", word))
}
