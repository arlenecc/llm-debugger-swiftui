import Foundation

// MARK: - 服务地址解析

public enum EndpointError: Error, LocalizedError, Equatable {
    case empty
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .empty:
            return "请先填写服务地址"
        case .invalid(let raw):
            return "服务地址无效：\(raw)"
        }
    }
}

public struct ResolvedEndpoints: Equatable, Sendable {
    /// 归一化后的 API 根路径，例如 `https://api.openai.com/v1`
    public let baseURL: URL
    public let modelsURL: URL
    public let chatCompletionsURL: URL

    public init(baseURL: URL, modelsURL: URL, chatCompletionsURL: URL) {
        self.baseURL = baseURL
        self.modelsURL = modelsURL
        self.chatCompletionsURL = chatCompletionsURL
    }
}

public enum EndpointResolver {
    /// 需要被剥离的已知端点后缀（用户可能直接粘贴完整地址）
    private static let knownEndpoints = [
        "chat/completions",
        "completions",
        "chat",
        "messages",
        "models",
        "responses"
    ]

    /// 形如 `v1` / `v1beta` / `v2.1` 的版本段
    private static let versionPattern = try! NSRegularExpression(pattern: "^v[0-9]+([a-zA-Z0-9._-]*)?$")

    /// 把用户填写的地址归一化成一组 OpenAI 兼容端点。
    ///
    /// - `https://api.openai.com`         → `https://api.openai.com/v1`
    /// - `https://api.openai.com/v1`      → `https://api.openai.com/v1`
    /// - `https://host/api/v1/chat/completions` → `https://host/api/v1`
    /// - `http://localhost:11434/v1`      → 保持
    /// - `api.openai.com`（无 scheme）     → 自动补全 `https://`
    public static func resolve(_ raw: String, versionPath: String = "v1") throws -> ResolvedEndpoints {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw EndpointError.empty }

        if !text.contains("://") {
            text = "https://" + text
        }

        guard var components = URLComponents(string: text),
              let scheme = components.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = components.host,
              !host.isEmpty
        else {
            throw EndpointError.invalid(raw)
        }

        // 归一化路径
        var segments = components.path
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        // 剥离已知的端点后缀
        if let last = segments.last?.lowercased(),
           knownEndpoints.contains(last) {
            segments.removeLast()
        }
        // 处理 `/v1/chat/completions` 这类：前面已经剥掉了最后一段，再剥一次
        if let last = segments.last?.lowercased(),
           knownEndpoints.contains(last) {
            segments.removeLast()
        }

        // 判断路径是否已经包含版本号
        let hasVersion = segments.contains { segment in
            let range = NSRange(segment.startIndex..., in: segment)
            return versionPattern.firstMatch(in: segment, range: range) != nil
        }

        if !hasVersion {
            let normalized = normalizedVersionPath(versionPath)
            if !normalized.isEmpty {
                segments.append(contentsOf: normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init))
            }
        }

        components.path = "/" + segments.joined(separator: "/")
        components.query = nil
        components.fragment = nil

        guard let baseURL = components.url else { throw EndpointError.invalid(raw) }

        let chat = baseURL
            .appendingPathComponent("chat")
            .appendingPathComponent("completions")

        return ResolvedEndpoints(
            baseURL: baseURL,
            modelsURL: baseURL.appendingPathComponent("models"),
            chatCompletionsURL: chat
        )
    }

    private static func normalizedVersionPath(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    }
}
