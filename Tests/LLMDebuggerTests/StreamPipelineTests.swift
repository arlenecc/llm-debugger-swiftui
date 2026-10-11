import Foundation
import LLMDebuggerCore

/// 用例组 K：流式管道（客户端 → SSE → 解码）
@MainActor
func streamPipelineTests() -> [MiniTest] {
    [
        MiniTest("K1 思考与回复分流") {
            let transport = MockTransport(handlers: ["/v1/chat/completions": .sse([
                sseLine(#"{"choices":[{"delta":{"reasoning_content":"先算一下"}}]}"#),
                sseLine(#"{"choices":[{"delta":{"reasoning_content":"再确认"}}]}"#),
                sseLine(#"{"choices":[{"delta":{"content":"结果是"}}]}"#),
                sseLine(#"{"choices":[{"delta":{"content":"42"}}]}"#),
                sseLine(#"{"choices":[{"delta":{},"finish_reason":"stop"}]}"#),
                "data: [DONE]\n\n"
            ])])
            let client = OpenAIClient(transport: transport)
            let events = try await collect(client.streamChat(
                baseURL: "https://api.openai.com",
                apiKey: "sk-test",
                messages: [WireMessage(role: .user, content: "1+1")],
                parameters: ChatParameters(model: "o3-mini")
            ))

            let thinking = events.map(\.thinkingDelta).joined()
            let answer = events.map(\.answerDelta).joined()
            try XCTAssertEqual(thinking, "先算一下再确认")
            try XCTAssertEqual(answer, "结果是42")
            try XCTAssertTrue(events.contains { $0.finishReason == "stop" })
        },

        MiniTest("K2 用量在最后一个 chunk 被解析") {
            let transport = MockTransport(handlers: ["/v1/chat/completions": .sse([
                sseLine(#"{"choices":[{"delta":{"content":"hi"}}]}"#),
                sseLine(#"{"choices":[],"usage":{"prompt_tokens":10,"completion_tokens":20,"total_tokens":30}}"#),
                "data: [DONE]\n\n"
            ])])
            let client = OpenAIClient(transport: transport)
            let events = try await collect(client.streamChat(
                baseURL: "https://api.openai.com",
                apiKey: "k",
                messages: [],
                parameters: ChatParameters(model: "m")
            ))
            try XCTAssertEqual(events.compactMap(\.usage).last?.total, 30)
        },

        MiniTest("K3 一个 chunk 里包含多个事件") {
            let transport = MockTransport(handlers: ["/v1/chat/completions": .sse([
                sseLine(#"{"choices":[{"delta":{"content":"A"}}]}"#)
                    + sseLine(#"{"choices":[{"delta":{"content":"B"}}]}"#)
            ])])
            let client = OpenAIClient(transport: transport)
            let events = try await collect(client.streamChat(
                baseURL: "https://api.openai.com",
                apiKey: "k",
                messages: [],
                parameters: ChatParameters(model: "m")
            ))
            try XCTAssertEqual(events.map(\.answerDelta).joined(), "AB")
        },

        MiniTest("K4 事件被网络 chunk 切断也能正确还原") {
            let full = sseLine(#"{"choices":[{"delta":{"content":"流式内容"}}]}"#)
            let bytes = Array(full.utf8)
            let mid = bytes.count / 2
            let transport = MockTransport(handlers: ["/v1/chat/completions": MockHTTPResponse(chunks: [
                Data(bytes[0..<mid]),
                Data(bytes[mid...])
            ])])
            let client = OpenAIClient(transport: transport)
            let events = try await collect(client.streamChat(
                baseURL: "https://api.openai.com",
                apiKey: "k",
                messages: [],
                parameters: ChatParameters(model: "m")
            ))
            try XCTAssertEqual(events.map(\.answerDelta).joined(), "流式内容")
        },

        MiniTest("K5 非法 JSON 不会中断整个流") {
            let transport = MockTransport(handlers: ["/v1/chat/completions": .sse([
                "data: {broken json\n\n",
                sseLine(#"{"choices":[{"delta":{"content":"ok"}}]}"#)
            ])])
            let logs = LogStore(capacity: 100, flushInterval: 0.01)
            let client = OpenAIClient(transport: transport, logger: logs)
            let events = try await collect(client.streamChat(
                baseURL: "https://api.openai.com",
                apiKey: "k",
                messages: [],
                parameters: ChatParameters(model: "m")
            ))
            try XCTAssertEqual(events.map(\.answerDelta).joined(), "ok")
            logs.flush()
            try XCTAssertTrue(logs.entries.contains { $0.level == .error })
        },

        MiniTest("K6 HTTP 错误码抛出 serverMessage") {
            let transport = MockTransport(handlers: [
                "/v1/chat/completions": .error("model not found", status: 404)
            ])
            let client = OpenAIClient(transport: transport)
            do {
                _ = try await collect(client.streamChat(
                    baseURL: "https://api.openai.com",
                    apiKey: "k",
                    messages: [],
                    parameters: ChatParameters(model: "m")
                ))
                try XCTFail("应当抛出错误")
            } catch let error as OpenAIError {
                try XCTAssertEqual(error, .serverMessage("model not found"))
            }
        },

        MiniTest("K7 服务端忽略 stream 参数时按完整 JSON 处理") {
            let payload = #"{"choices":[{"message":{"role":"assistant","content":"一次性返回"},"finish_reason":"stop"}],"usage":{"total_tokens":9}}"#
            let transport = MockTransport(handlers: ["/v1/chat/completions": .json(payload)])
            let client = OpenAIClient(transport: transport)
            let events = try await collect(client.streamChat(
                baseURL: "https://api.openai.com",
                apiKey: "k",
                messages: [],
                parameters: ChatParameters(model: "m")
            ))
            try XCTAssertEqual(events.map(\.answerDelta).joined(), "一次性返回")
            try XCTAssertEqual(events.compactMap(\.usage).last?.total, 9)
        },

        MiniTest("K8 content 中的 think 标签被路由到思考过程") {
            let transport = MockTransport(handlers: ["/v1/chat/completions": .sse([
                sseLine(#"{"choices":[{"delta":{"content":"<think>推理中"}}]}"#),
                sseLine(#"{"choices":[{"delta":{"content":"</think>答案"}}]}"#)
            ])])
            let client = OpenAIClient(transport: transport)
            let events = try await collect(client.streamChat(
                baseURL: "https://api.openai.com",
                apiKey: "k",
                messages: [],
                parameters: ChatParameters(model: "m", routeThinkTags: true)
            ))
            try XCTAssertEqual(events.map(\.thinkingDelta).joined(), "推理中")
            try XCTAssertEqual(events.map(\.answerDelta).joined(), "答案")
        },

        MiniTest("K9 取消流时不再产出事件") {
            let chunk = Data(sseLine(#"{"choices":[{"delta":{"content":"x"}}]}"#).utf8)
            let transport = NeverEndingStreamTransport(chunk: chunk, chunkDelay: 0.01)
            let client = OpenAIClient(transport: transport)
            let stream = client.streamChat(baseURL: "https://api.openai.com",
                                           apiKey: "k",
                                           messages: [],
                                           parameters: ChatParameters(model: "m"))

            let task = Task {
                var count = 0
                for try await _ in stream {
                    count += 1
                    if count > 20 { break }
                }
                return count
            }
            try? await Task.sleep(nanoseconds: 150_000_000)
            task.cancel()
            let value = try await task.value
            try XCTAssertGreaterThan(value, 0)
        },

        MiniTest("K10 原始 SSE 数据被写入日志") {
            let logs = LogStore(capacity: 100, flushInterval: 0.01)
            let transport = MockTransport(handlers: ["/v1/chat/completions": .sse([
                sseLine(#"{"choices":[{"delta":{"content":"A"}}]}"#)
            ])])
            let client = OpenAIClient(transport: transport, logger: logs)
            _ = try await collect(client.streamChat(baseURL: "https://api.openai.com",
                                                    apiKey: "k",
                                                    messages: [],
                                                    parameters: ChatParameters(model: "m")))
            logs.flush()
            let streamLogs = logs.entries.filter { $0.level == .stream }
            try XCTAssertTrue(streamLogs.contains { $0.text.contains("\"content\":\"A\"") })
        },

        MiniTest("K11 响应状态被写入日志") {
            let logs = LogStore(capacity: 100, flushInterval: 0.01)
            let transport = MockTransport(handlers: ["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            let client = OpenAIClient(transport: transport, logger: logs)
            _ = try await collect(client.streamChat(baseURL: "https://api.openai.com",
                                                    apiKey: "k",
                                                    messages: [],
                                                    parameters: ChatParameters(model: "m")))
            logs.flush()
            try XCTAssertTrue(logs.entries.contains { $0.level == .response && $0.text.contains("HTTP 200") })
        }
    ]
}

// MARK: - 辅助

private func sseLine(_ payload: String) -> String {
    "data: \(payload)\n\n"
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var result: [StreamEvent] = []
    for try await event in stream { result.append(event) }
    return result
}
