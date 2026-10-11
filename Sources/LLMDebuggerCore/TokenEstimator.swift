import Foundation

// MARK: - Token 估算

/// 在服务端未返回 `usage` 时给出可用的估算值。
/// 规则（确定性、可测试）：
/// - CJK 字符按 1 字符 ≈ 1 token；
/// - 其余字符按 4 字符 ≈ 1 token（向上取整）。
public enum TokenEstimator {
    public static func estimate(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }

        var total = 0
        var asciiRun = 0

        for scalar in text.unicodeScalars {
            if isCJK(scalar) {
                if asciiRun > 0 {
                    total += Int(ceil(Double(asciiRun) / 4.0))
                    asciiRun = 0
                }
                total += 1
            } else {
                asciiRun += 1
            }
        }
        if asciiRun > 0 {
            total += Int(ceil(Double(asciiRun) / 4.0))
        }
        return total
    }

    public static func estimate(messages: [WireMessage]) -> Int {
        // 每条消息额外计入角色与分隔开销
        let overheadPerMessage = 4
        let total = messages.reduce(0) { $0 + estimate($1.content) + overheadPerMessage }
        return total + 2
    }

    private static func isCJK(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        return (v >= 0x4E00 && v <= 0x9FFF)     // CJK 统一汉字
            || (v >= 0x3400 && v <= 0x4DBF)     // 扩展 A
            || (v >= 0xF900 && v <= 0xFAFF)     // 兼容汉字
            || (v >= 0x3040 && v <= 0x30FF)     // 日文假名
            || (v >= 0xAC00 && v <= 0xD7AF)     // 韩文音节
            || (v >= 0x3000 && v <= 0x303F)     // CJK 标点
            || (v >= 0xFF00 && v <= 0xFFEF)     // 全角符号
    }
}
