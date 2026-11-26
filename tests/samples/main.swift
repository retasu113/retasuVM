import Foundation

// 内蔵サンプルの完全性ハーネス: 各サンプルの SHA-256 が定義値と一致するか検証する。
var allOK = true
for sample in BuiltInSample.allCases {
    let digest = SHA256.hash(sample.data).map { String(format: "%02x", $0) }.joined()
    let ok = digest == sample.sha256
    if !ok { allOK = false }
    print("\(sample.rawValue): \(ok ? "OK" : "NG") (\(sample.data.count) bytes)")
}
print(allOK ? "ALL SAMPLES OK" : "SAMPLES NG")
