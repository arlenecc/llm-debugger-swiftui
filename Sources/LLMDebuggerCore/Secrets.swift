import Foundation

// MARK: - 敏感信息脱敏

public enum Secrets {
    /// 对密钥做脱敏，保留少量前后缀用于人工核对，避免日志泄露完整密钥
    public static func mask(_ value: String) -> String {
        if value.isEmpty { return "" }
        let chars = Array(value)
        if chars.count <= 8 {
            return String(repeating: "*", count: chars.count)
        }
        let prefix = String(chars.prefix(3))
        let suffix = String(chars.suffix(4))
        return "\(prefix)***\(suffix)"
    }

    /// 对请求头做脱敏（Authorization / 各类 api-key 头）
    public static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        var output = headers
        for key in output.keys {
            let lowered = key.lowercased()
            guard lowered == "authorization"
                || lowered == "x-api-key"
                || lowered == "api-key"
                || lowered.contains("apikey")
                || lowered.contains("api-key")
            else { continue }
            output[key] = redactBearer(output[key] ?? "")
        }
        return output
    }

    private static func redactBearer(_ value: String) -> String {
        let lower = value.lowercased()
        if lower.hasPrefix("bearer ") {
            let token = String(value.dropFirst("bearer ".count))
            return "Bearer " + mask(token)
        }
        return mask(value)
    }

    /// 把一段文本里出现的密钥整体替换掉（用于兜底，防止任何路径泄露）
    public static func redact(_ text: String, secret: String) -> String {
        guard !secret.isEmpty, text.contains(secret) else { return text }
        return text.replacingOccurrences(of: secret, with: mask(secret))
    }
}
