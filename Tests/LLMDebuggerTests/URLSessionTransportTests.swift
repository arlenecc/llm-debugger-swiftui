import Foundation
import LLMDebuggerCore

/// 用例组 M：真实 URLSession 流式读取（本地 HTTP 服务端）
@MainActor
func urlSessionTransportTests() -> [MiniTest] {
    [
        MiniTest("M1 通过真实 URLSession 流式读取 SSE") {
            let server = try TestHTTPServer { path in
                if path.hasSuffix("/chat/completions") {
                    return MockHTTPResponse(chunks: [
                        Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"想\"}}]}\n\n".utf8),
                        Data("data: {\"choices\":[{\"delta\":{\"content\":\"答\"}}]}\n\n".utf8),
                        Data("data: [DONE]\n\n".utf8)
                    ])
                }
                return MockHTTPResponse.json("{}", status: 404)
            }
            defer { server.stop() }

            let port = try await server.port()
            let logs = LogStore(capacity: 200, flushInterval: 0.01)
            let client = OpenAIClient(transport: URLSessionTransport(), logger: logs)

            var thinking = ""
            var answer = ""
            let stream = client.streamChat(baseURL: "http://127.0.0.1:\(port)/v1",
                                           apiKey: "sk-local",
                                           messages: [WireMessage(role: .user, content: "hi")],
                                           parameters: ChatParameters(model: "local-model"))
            for try await event in stream {
                thinking += event.thinkingDelta
                answer += event.answerDelta
            }

            try XCTAssertEqual(thinking, "想")
            try XCTAssertEqual(answer, "答")
        },

        MiniTest("M2 真实网络下的分块字节中文不乱码") {
            let payload = "data: {\"choices\":[{\"delta\":{\"content\":\"中文流式输出测试\"}}]}\n\n"
            let bytes = Array(payload.utf8)
            let server = try TestHTTPServer { _ in
                MockHTTPResponse(chunks: bytes.map { Data([$0]) })
            }
            defer { server.stop() }

            let port = try await server.port()
            let client = OpenAIClient(transport: URLSessionTransport())

            var answer = ""
            let stream = client.streamChat(baseURL: "http://127.0.0.1:\(port)/v1",
                                           apiKey: "",
                                           messages: [WireMessage(role: .user, content: "hi")],
                                           parameters: ChatParameters(model: "m"))
            for try await event in stream {
                answer += event.answerDelta
            }
            try XCTAssertEqual(answer, "中文流式输出测试")
        },

        MiniTest("M4 端到端：真实网络下的完整界面流程") {
            let server = try TestHTTPServer { path in
                switch path {
                case let p where p.hasSuffix("/v1/models"):
                    return MockHTTPResponse.json(
                        #"{"object":"list","data":[{"id":"deepseek-r1"},{"id":"qwen3"},{"id":"gpt-4o"}]}"#)
                case let p where p.hasSuffix("/v1/chat/completions"):
                    return MockHTTPResponse(chunks: [
                        Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"先分析题意\"}}]}\n\n".utf8),
                        Data("data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"，再给出结论\"}}]}\n\n".utf8),
                        Data("data: {\"choices\":[{\"delta\":{\"content\":\"答案是\"}}]}\n\n".utf8),
                        Data("data: {\"choices\":[{\"delta\":{\"content\":\"42\"}}]}\n\n".utf8),
                        Data("data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":13,\"completion_tokens\":29,\"total_tokens\":42,\"completion_tokens_details\":{\"reasoning_tokens\":17}}}\n\n".utf8),
                        Data("data: [DONE]\n\n".utf8)
                    ])
                default:
                    return MockHTTPResponse.json("{}", status: 404)
                }
            }
            defer { server.stop() }

            let port = try await server.port()
            let logs = LogStore(capacity: 500, flushInterval: 0.01)
            let session = ChatSession(transport: URLSessionTransport(), logger: logs, persist: false)
            session.baseURL = "http://127.0.0.1:\(port)/v1"
            session.apiKey = "sk-local-test"
            session.model = ""

            await session.refreshModels()
            try XCTAssertEqual(session.models.count, 3)
            try XCTAssertEqual(session.model, "deepseek-r1", "应自动填入首个模型")

            session.send("1+1 等于几？")
            await session.waitUntilIdle()

            try XCTAssertEqual(session.messages.count, 2)
            try XCTAssertEqual(session.messages[1].content, "答案是42")
            try XCTAssertEqual(session.messages[1].thinking, "先分析题意，再给出结论")
            try XCTAssertEqual(session.displayedThinking, "先分析题意，再给出结论")
            try XCTAssertEqual(session.usage?.total, 42)
            try XCTAssertEqual(session.usage?.reasoningTokens, 17)
            try XCTAssertFalse(session.isStreaming)

            // 日志区应能看到请求、响应与原始流数据，且不泄露密钥
            logs.flush()
            let texts = logs.entries.map(\.text).joined(separator: "\n")
            try XCTAssertTrue(texts.contains("POST"))
            try XCTAssertTrue(texts.contains("HTTP 200"))
            try XCTAssertTrue(texts.contains("reasoning_content"))
            try XCTAssertFalse(texts.contains("sk-local-test"))
        },

        MiniTest("M3 真实网络下 HTTP 错误被正确抛出") {
            let server = try TestHTTPServer { _ in
                MockHTTPResponse.json("{\"error\":{\"message\":\"bad request\"}}", status: 400)
            }
            defer { server.stop() }

            let port = try await server.port()
            let client = OpenAIClient(transport: URLSessionTransport())

            let stream = client.streamChat(baseURL: "http://127.0.0.1:\(port)/v1",
                                           apiKey: "",
                                           messages: [],
                                           parameters: ChatParameters(model: "m"))
            do {
                for try await _ in stream { }
                try XCTFail("应当抛出错误")
            } catch let error as OpenAIError {
                try XCTAssertEqual(error, .serverMessage("bad request"))
            }
        }
    ]
}
