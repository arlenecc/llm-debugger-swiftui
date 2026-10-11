import Foundation

// MARK: - 响应体的原始结构

struct RawUsage: Decodable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    let promptDetails: Details?
    let completionDetails: Details?

    struct Details: Decodable {
        let reasoningTokens: Int?
        enum CodingKeys: String, CodingKey {
            case reasoningTokens = "reasoning_tokens"
        }
    }

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case promptDetails = "prompt_tokens_details"
        case completionDetails = "completion_tokens_details"
    }

    func toUsageInfo() -> UsageInfo {
        UsageInfo(
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            totalTokens: totalTokens,
            reasoningTokens: completionDetails?.reasoningTokens ?? promptDetails?.reasoningTokens,
            estimated: false
        )
    }
}

struct RawError: Decodable {
    let message: String

    enum CodingKeys: String, CodingKey { case message }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: CodingKeys.self),
           let message = try? container.decode(String.self, forKey: .message) {
            self.message = message
            return
        }
        if let single = try? decoder.singleValueContainer(),
           let message = try? single.decode(String.self) {
            self.message = message
            return
        }
        self.message = "未知错误"
    }
}

struct RawChunk: Decodable {
    struct Delta: Decodable {
        let role: String?
        let content: String?
        /// DeepSeek / vLLM / 多数兼容实现
        let reasoningContent: String?
        /// 部分实现直接用 reasoning
        let reasoning: String?
        /// 少数实现用 thinking
        let thinking: String?

        enum CodingKeys: String, CodingKey {
            case role
            case content
            case reasoningContent = "reasoning_content"
            case reasoning
            case thinking
        }

        enum NestedKeys: String, CodingKey {
            case content
            case text
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            role = try container.decodeIfPresent(String.self, forKey: .role)
            content = try container.decodeIfPresent(String.self, forKey: .content)
            reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
            thinking = try container.decodeIfPresent(String.self, forKey: .thinking)
            reasoning = Self.decodeReasoning(from: container)
        }

        /// `reasoning` 可能是字符串，也可能是 `{"content": "..."}` 对象
        private static func decodeReasoning(from container: KeyedDecodingContainer<CodingKeys>) -> String? {
            if let value = try? container.decode(String.self, forKey: .reasoning) {
                return value
            }
            if let nested = try? container.nestedContainer(keyedBy: NestedKeys.self, forKey: .reasoning) {
                if let value = try? nested.decode(String.self, forKey: .content) { return value }
                if let value = try? nested.decode(String.self, forKey: .text) { return value }
            }
            return nil
        }

        var reasoningText: String? {
            if let reasoningContent, !reasoningContent.isEmpty { return reasoningContent }
            if let reasoning, !reasoning.isEmpty { return reasoning }
            if let thinking, !thinking.isEmpty { return thinking }
            return nil
        }
    }

    struct Choice: Decodable {
        let index: Int?
        let delta: Delta?
        let message: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case index
            case delta
            case message
            case finishReason = "finish_reason"
        }
    }

    let id: String?
    let object: String?
    let model: String?
    let choices: [Choice]?
    let usage: RawUsage?
    let error: RawError?

    enum CodingKeys: String, CodingKey {
        case id, object, model, choices, usage, error
    }
}

// MARK: - 解码器

/// 把 SSE 的 `data:` 负载解码成 `StreamEvent`
public final class ChunkDecoder {
    private var router: ThinkTagRouter
    private let routeThinkTags: Bool

    public init(routeThinkTags: Bool = true) {
        self.routeThinkTags = routeThinkTags
        self.router = ThinkTagRouter()
    }

    public func reset() {
        router.reset()
    }

    /// - Throws: `ChunkDecodeError.invalidJSON` 当负载不是合法 JSON
    /// - Returns: 解析结果；返回 `nil` 表示没有有效内容（例如空 data）
    public func decode(_ payload: String) throws -> StreamEvent? {
        let trimmed = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8) else { return nil }

        let raw: RawChunk
        do {
            raw = try JSONDecoder().decode(RawChunk.self, from: data)
        } catch {
            throw ChunkDecodeError.invalidJSON(trimmed)
        }

        var event = StreamEvent()
        event.model = raw.model

        if let error = raw.error {
            event.errorMessage = error.message
        }

        if let usage = raw.usage {
            event.usage = usage.toUsageInfo()
        }

        if let choice = raw.choices?.first {
            let delta = choice.delta ?? choice.message
            if let finish = choice.finishReason {
                event.finishReason = finish
            }
            if let reasoning = delta?.reasoningText {
                event.thinkingDelta += reasoning
            }
            if let content = delta?.content, !content.isEmpty {
                if routeThinkTags {
                    let routed = router.route(content)
                    event.thinkingDelta += routed.thinking
                    event.answerDelta += routed.answer
                } else {
                    event.answerDelta += content
                }
            }
        }

        if event.isEmpty { return nil }
        return event
    }

    /// 流结束时吐出路由器里可能残留的内容
    public func finish() -> StreamEvent? {
        guard routeThinkTags else { return nil }
        let flushed = router.finish()
        if flushed.thinking.isEmpty && flushed.answer.isEmpty { return nil }
        return StreamEvent(thinkingDelta: flushed.thinking, answerDelta: flushed.answer)
    }
}
