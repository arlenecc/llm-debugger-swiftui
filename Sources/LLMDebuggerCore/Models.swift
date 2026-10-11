import Foundation

// MARK: - 基础模型

public enum ChatRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case system
    case user
    case assistant

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "系统"
        case .user: return "我"
        case .assistant: return "助手"
        }
    }
}

public struct ModelInfo: Hashable, Sendable, Identifiable {
    public let id: String
    public let ownedBy: String?

    public init(id: String, ownedBy: String? = nil) {
        self.id = id
        self.ownedBy = ownedBy
    }
}

/// 一次对话在「线上」的表示形式（直接用于组装请求体）
public struct WireMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }

    public init(role: ChatRole, content: String) {
        self.role = role.rawValue
        self.content = content
    }
}

// MARK: - Token 用量

public struct UsageInfo: Equatable, Sendable {
    public var promptTokens: Int?
    public var completionTokens: Int?
    public var totalTokens: Int?
    public var reasoningTokens: Int?
    /// 服务端未返回用量，数值为本地估算
    public var estimated: Bool

    public init(
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        totalTokens: Int? = nil,
        reasoningTokens: Int? = nil,
        estimated: Bool = false
    ) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.reasoningTokens = reasoningTokens
        self.estimated = estimated
    }

    public var total: Int {
        if let totalTokens { return totalTokens }
        return (promptTokens ?? 0) + (completionTokens ?? 0)
    }

    public var isEmpty: Bool {
        promptTokens == nil && completionTokens == nil && totalTokens == nil
    }
}

// MARK: - 流式事件

/// 解码后的增量事件：`thinkingDelta` 为思考过程，`answerDelta` 为最终回复。
public struct StreamEvent: Equatable, Sendable {
    public var thinkingDelta: String = ""
    public var answerDelta: String = ""
    public var finishReason: String?
    public var usage: UsageInfo?
    public var model: String?
    public var errorMessage: String?

    public init(
        thinkingDelta: String = "",
        answerDelta: String = "",
        finishReason: String? = nil,
        usage: UsageInfo? = nil,
        model: String? = nil,
        errorMessage: String? = nil
    ) {
        self.thinkingDelta = thinkingDelta
        self.answerDelta = answerDelta
        self.finishReason = finishReason
        self.usage = usage
        self.model = model
        self.errorMessage = errorMessage
    }

    public var isEmpty: Bool {
        thinkingDelta.isEmpty && answerDelta.isEmpty
            && finishReason == nil && usage == nil && model == nil && errorMessage == nil
    }
}

// MARK: - 错误

public enum OpenAIError: Error, LocalizedError, Equatable {
    case invalidBaseURL(String)
    case httpError(status: Int, body: String)
    case serverMessage(String)
    case invalidResponse
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let raw):
            return "服务地址无效：\(raw)"
        case .httpError(let status, let body):
            let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "HTTP \(status)" }
            return "HTTP \(status)：\(trimmed)"
        case .serverMessage(let message):
            return "服务端错误：\(message)"
        case .invalidResponse:
            return "响应格式无法解析"
        case .cancelled:
            return "请求已取消"
        }
    }
}

public enum ChunkDecodeError: Error, LocalizedError, Equatable {
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSON(let raw):
            return "无法解析的流式数据：\(raw)"
        }
    }
}
