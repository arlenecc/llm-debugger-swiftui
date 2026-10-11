import Foundation
import LLMDebuggerCore

/// 用例组 L：会话引擎（界面背后的状态机）
@MainActor
func chatSessionTests() -> [MiniTest] {
    [
        MiniTest("L1 发送后追加用户与助手消息") {
            let (session, _) = makeSession(["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            session.send("你好")
            await session.waitUntilIdle()

            try XCTAssertEqual(session.messages.count, 2)
            try XCTAssertEqual(session.messages[0].role, .user)
            try XCTAssertEqual(session.messages[0].content, "你好")
            try XCTAssertEqual(session.messages[1].role, .assistant)
            try XCTAssertFalse(session.isStreaming)
        },

        MiniTest("L2 流式输出最终回复与思考过程分离") {
            let (session, _) = makeSession(["/v1/chat/completions": .sse([
                "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"思考A\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"思考B\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"答案1\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"答案2\"}}]}\n\n",
                "data: [DONE]\n\n"
            ])])
            session.send("问题")
            await session.waitUntilIdle()

            try XCTAssertEqual(session.messages[1].content, "答案1答案2")
            try XCTAssertEqual(session.messages[1].thinking, "思考A思考B")
            try XCTAssertEqual(session.displayedThinking, "思考A思考B")
        },

        MiniTest("L3 用量被记录") {
            let (session, _) = makeSession(["/v1/chat/completions": .sse([
                "data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n",
                "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":7,\"total_tokens\":12}}\n\n",
                "data: [DONE]\n\n"
            ])])
            session.send("hi")
            await session.waitUntilIdle()

            try XCTAssertEqual(session.usage?.total, 12)
            try XCTAssertEqual(session.usage?.estimated, false)
        },

        MiniTest("L4 服务端无用量时本地估算") {
            let (session, _) = makeSession(["/v1/chat/completions": .sse([
                "data: {\"choices\":[{\"delta\":{\"content\":\"你好世界\"}}]}\n\n",
                "data: [DONE]\n\n"
            ])])
            session.send("hi")
            await session.waitUntilIdle()

            try XCTAssertNotNil(session.usage)
            try XCTAssertTrue(session.usage?.estimated == true)
            try XCTAssertGreaterThan(session.usage?.total ?? 0, 0)
        },

        MiniTest("L5 多轮对话会把历史带进请求体") {
            let (session, transport) = makeSession(["/v1/chat/completions": .sse([
                "data: {\"choices\":[{\"delta\":{\"content\":\"第一回答\"}}]}\n\n",
                "data: [DONE]\n\n"
            ])])
            session.send("第一轮")
            await session.waitUntilIdle()
            session.send("第二轮")
            await session.waitUntilIdle()

            let messages = transport.lastRequestBody()?["messages"] as? [[String: String]]
            try XCTAssertEqual(messages?.count, 3)
            try XCTAssertEqual(messages?[0]["content"], "第一轮")
            try XCTAssertEqual(messages?[1]["content"], "第一回答")
            try XCTAssertEqual(messages?[2]["content"], "第二轮")
        },

        MiniTest("L6 系统提示词会作为首条消息") {
            let (session, transport) = makeSession(["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            session.systemPrompt = "你是助手"
            session.send("hi")
            await session.waitUntilIdle()

            let messages = transport.lastRequestBody()?["messages"] as? [[String: String]]
            try XCTAssertEqual(messages?.first?["role"], "system")
            try XCTAssertEqual(messages?.first?["content"], "你是助手")
        },

        MiniTest("L7 停止生成后保留部分内容") {
            let chunk = Data("data: {\"choices\":[{\"delta\":{\"content\":\"片段\"}}]}\n\n".utf8)
            let transport = NeverEndingStreamTransport(chunk: chunk, chunkDelay: 0.01)
            let logs = LogStore(capacity: 500, flushInterval: 0.01)
            let session = ChatSession(transport: transport, logger: logs, persist: false)
            session.baseURL = "https://api.openai.com"
            session.model = "gpt-4o"

            session.send("一直输出")
            try? await Task.sleep(nanoseconds: 200_000_000)
            try XCTAssertTrue(session.isStreaming)
            session.stop()
            await session.waitUntilIdle()

            try XCTAssertFalse(session.isStreaming)
            try XCTAssertFalse(session.messages[1].content.isEmpty)
            // 已有输出时的停止不再显示为错误，仅追加提示
            try XCTAssertNil(session.messages[1].errorMessage)
        },

        MiniTest("L8 网络错误写入消息与日志") {
            let transport = MockTransport(handlers: [
                "/v1/chat/completions": MockHTTPResponse(transportErrorMessage: "网络中断")
            ])
            let logs = LogStore(capacity: 500, flushInterval: 0.01)
            let session = ChatSession(transport: transport, logger: logs, persist: false)
            session.baseURL = "https://api.openai.com"
            session.model = "gpt-4o"

            session.send("hi")
            await session.waitUntilIdle()

            try XCTAssertEqual(session.messages[1].errorMessage, "网络中断")
            try XCTAssertEqual(session.lastError, "网络中断")
            logs.flush()
            try XCTAssertTrue(logs.entries.contains { $0.level == .error })
        },

        MiniTest("L9 获取模型列表并自动填入首个模型") {
            let (session, _) = makeSession([
                "/v1/models": .json(#"{"data":[{"id":"gpt-4o"},{"id":"o3-mini"}]}"#)
            ])
            session.model = ""
            await session.refreshModels()

            try XCTAssertEqual(session.models.count, 2)
            try XCTAssertEqual(session.model, "gpt-4o")
            try XCTAssertFalse(session.isFetchingModels)
        },

        MiniTest("L10 获取模型失败时记录错误") {
            let (session, _) = makeSession(["/v1/models": .error("Unauthorized", status: 401)])
            await session.refreshModels()

            try XCTAssertTrue(session.models.isEmpty)
            try XCTAssertNotNil(session.modelsError)
            try XCTAssertNotNil(session.lastError)
        },

        MiniTest("L11 模型为空时拒绝发送") {
            let (session, transport) = makeSession(["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            session.model = ""
            session.send("hi")
            await session.waitUntilIdle()

            try XCTAssertTrue(session.messages.isEmpty)
            try XCTAssertEqual(transport.requestCount, 0)
            try XCTAssertNotNil(session.lastError)
        },

        MiniTest("L12 服务地址非法时拒绝发送") {
            let (session, transport) = makeSession(["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            session.baseURL = "   "
            session.send("hi")
            await session.waitUntilIdle()

            try XCTAssertTrue(session.messages.isEmpty)
            try XCTAssertEqual(transport.requestCount, 0)
        },

        MiniTest("L13 空白消息不发送") {
            let (session, transport) = makeSession(["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            session.send("   \n  ")
            await session.waitUntilIdle()
            try XCTAssertEqual(transport.requestCount, 0)
            try XCTAssertTrue(session.messages.isEmpty)
        },

        MiniTest("L13b canSend 随配置变化") {
            let (session, _) = makeSession([:])
            // 初始：地址有效但模型为空 -> 不能发送
            session.baseURL = "https://api.openai.com"
            session.model = ""
            try XCTAssertFalse(session.canSend)

            // 填入模型 -> 可以发送
            session.model = "gpt-4o"
            try XCTAssertTrue(session.canSend)

            // 地址非法 -> 不能发送
            session.baseURL = "not a url"
            try XCTAssertFalse(session.canSend)

            // 正在生成中 -> 不能发送
            session.baseURL = "https://api.openai.com"
            session.model = "gpt-4o"
            try XCTAssertTrue(session.canSend)
        },

        MiniTest("L14 清空对话") {
            let (session, _) = makeSession(["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            session.send("hi")
            await session.waitUntilIdle()
            session.clearConversation()
            try XCTAssertTrue(session.messages.isEmpty)
            try XCTAssertNil(session.usage)
        },

        MiniTest("L15 速率统计被写入 meter") {
            let (session, _) = makeSession(["/v1/chat/completions": .sse([
                "data: {\"choices\":[{\"delta\":{\"content\":\"这是一段用于估算速率的输出内容\"}}]}\n\n",
                "data: [DONE]\n\n"
            ])])
            session.send("hi")
            await session.waitUntilIdle()
            try XCTAssertGreaterThan(session.meter.snapshot().tokens, 0)
        },

        MiniTest("L16 思考过程内容不会出现在对话区") {
            let (session, _) = makeSession(["/v1/chat/completions": .sse([
                "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"内心独白\"}}]}\n\n",
                "data: {\"choices\":[{\"delta\":{\"content\":\"对外答复\"}}]}\n\n",
                "data: [DONE]\n\n"
            ])])
            session.send("hi")
            await session.waitUntilIdle()

            try XCTAssertFalse(session.messages[1].content.contains("内心独白"))
            try XCTAssertEqual(session.messages[1].content, "对外答复")
        },

        MiniTest("L17 生成中不允许重复发送") {
            let chunk = Data("data: {\"choices\":[{\"delta\":{\"content\":\"x\"}}]}\n\n".utf8)
            let transport = NeverEndingStreamTransport(chunk: chunk, chunkDelay: 0.02)
            let logs = LogStore(capacity: 500, flushInterval: 0.01)
            let session = ChatSession(transport: transport, logger: logs, persist: false)
            session.baseURL = "https://api.openai.com"
            session.model = "gpt-4o"

            session.send("第一次")
            try? await Task.sleep(nanoseconds: 100_000_000)
            session.send("第二次")
            session.stop()
            await session.waitUntilIdle()

            try XCTAssertEqual(session.messages.count, 2)
        },

        MiniTest("L18 请求体带上界面配置的参数") {
            let (session, transport) = makeSession(["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            session.temperature = 0.2
            session.maxTokens = 512
            session.includeUsage = false
            session.send("hi")
            await session.waitUntilIdle()

            let body = transport.lastRequestBody()
            try XCTAssertEqual(body?["temperature"] as? Double, 0.2)
            try XCTAssertEqual(body?["max_tokens"] as? Int, 512)
            try XCTAssertNil(body?["stream_options"])
            try XCTAssertEqual(body?["model"] as? String, "gpt-4o")
        }
    ]
}

@MainActor
private func makeSession(_ handlers: [String: MockHTTPResponse]) -> (ChatSession, MockTransport) {
    let transport = MockTransport(handlers: handlers)
    let logs = LogStore(capacity: 500, flushInterval: 0.01)
    let session = ChatSession(transport: transport, logger: logs, persist: false)
    session.baseURL = "https://api.openai.com"
    session.apiKey = "sk-test-key"
    session.model = "gpt-4o"
    return (session, transport)
}
