import Foundation
import LLMDebuggerCore

/// 用例组 I：请求组装
@MainActor
func requestBuilderTests() -> [MiniTest] {
    [
        MiniTest("I1 模型列表请求方法与地址") {
            let transport = MockTransport()
            let client = OpenAIClient(transport: transport)
            let request = try client.makeModelsRequest(baseURL: "https://api.openai.com", apiKey: "sk-test")
            try XCTAssertEqual(request.httpMethod, "GET")
            try XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/models")
        },

        MiniTest("I2 对话请求方法与地址") {
            let transport = MockTransport()
            let client = OpenAIClient(transport: transport)
            let request = try client.makeChatRequest(
                baseURL: "https://api.openai.com",
                apiKey: "sk-test",
                messages: [WireMessage(role: .user, content: "hi")],
                parameters: ChatParameters(model: "gpt-4o")
            )
            try XCTAssertEqual(request.httpMethod, "POST")
            try XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/chat/completions")
            try XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        },

        MiniTest("I3 带 apiKey 时写入 Authorization 头") {
            let transport = MockTransport()
            let client = OpenAIClient(transport: transport)
            let request = try client.makeChatRequest(
                baseURL: "https://api.openai.com",
                apiKey: "sk-abc",
                messages: [],
                parameters: ChatParameters(model: "m")
            )
            try XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-abc")
        },

        MiniTest("I4 apiKey 为空时不写入 Authorization 头") {
            let transport = MockTransport()
            let client = OpenAIClient(transport: transport)
            let request = try client.makeChatRequest(
                baseURL: "http://localhost:11434/v1",
                apiKey: "",
                messages: [],
                parameters: ChatParameters(model: "m")
            )
            try XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        },

        MiniTest("I5 请求体包含关键字段") {
            let body = OpenAIClient.makeChatRequestBody(
                messages: [WireMessage(role: .user, content: "hi")],
                parameters: ChatParameters(model: "gpt-4o", temperature: 0.3, maxTokens: 100)
            )
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            try XCTAssertNotNil(json)
            try XCTAssertEqual(json?["model"] as? String, "gpt-4o")
            try XCTAssertEqual(json?["stream"] as? Bool, true)
            try XCTAssertEqual(json?["temperature"] as? Double, 0.3)
            try XCTAssertEqual(json?["max_tokens"] as? Int, 100)
            let messages = json?["messages"] as? [[String: String]]
            try XCTAssertEqual(messages?.count, 1)
            try XCTAssertEqual(messages?.first?["role"], "user")
            try XCTAssertEqual(messages?.first?["content"], "hi")
        },

        MiniTest("I6 开启 usage 时附带 stream_options") {
            let body = OpenAIClient.makeChatRequestBody(
                messages: [],
                parameters: ChatParameters(model: "m", includeUsage: true)
            )
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let options = json?["stream_options"] as? [String: Any]
            try XCTAssertEqual(options?["include_usage"] as? Bool, true)
        },

        MiniTest("I7 关闭 usage 时不附带 stream_options") {
            let body = OpenAIClient.makeChatRequestBody(
                messages: [],
                parameters: ChatParameters(model: "m", includeUsage: false)
            )
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            try XCTAssertNil(json?["stream_options"])
        },

        MiniTest("I8 可选参数为空时不写入请求体") {
            let body = OpenAIClient.makeChatRequestBody(
                messages: [],
                parameters: ChatParameters(model: "m", temperature: nil, topP: nil, maxTokens: nil)
            )
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            try XCTAssertNil(json?["temperature"])
            try XCTAssertNil(json?["top_p"])
            try XCTAssertNil(json?["max_tokens"])
        },

        MiniTest("I9 日志中不会出现完整 apiKey") {
            let logs = LogStore(capacity: 100, flushInterval: 0.01)
            let transport = MockTransport(handlers: ["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            let client = OpenAIClient(transport: transport, logger: logs)
            let secret = "sk-super-secret-key-123456"
            let stream = client.streamChat(baseURL: "https://api.openai.com",
                                           apiKey: secret,
                                           messages: [WireMessage(role: .user, content: "hi")],
                                           parameters: ChatParameters(model: "gpt-4o"))
            for try await _ in stream { }
            logs.flush()
            let all = logs.entries.map(\.text).joined(separator: "\n")
            try XCTAssertFalse(all.contains(secret))
        },

        MiniTest("I10 请求日志记录了方法与地址") {
            let logs = LogStore(capacity: 100, flushInterval: 0.01)
            let transport = MockTransport(handlers: ["/v1/chat/completions": .sse(["data: [DONE]\n\n"])])
            let client = OpenAIClient(transport: transport, logger: logs)
            let stream = client.streamChat(baseURL: "https://api.openai.com",
                                           apiKey: "sk-test",
                                           messages: [],
                                           parameters: ChatParameters(model: "m"))
            for try await _ in stream { }
            logs.flush()
            let requestLog = logs.entries.first { $0.level == .request }
            try XCTAssertNotNil(requestLog)
            try XCTAssertTrue(requestLog?.text.contains("POST") == true)
            try XCTAssertTrue(requestLog?.text.contains("/v1/chat/completions") == true)
        }
    ]
}

/// 用例组 J：模型列表解析
@MainActor
func modelsParsingTests() -> [MiniTest] {
    [
        MiniTest("J1 标准 OpenAI 格式") {
            let json = """
            {"object":"list","data":[{"id":"gpt-4o","owned_by":"openai"},{"id":"gpt-4o-mini","owned_by":"system"}]}
            """
            let models = try OpenAIClient.parseModels(Data(json.utf8))
            try XCTAssertEqual(models.map(\.id), ["gpt-4o", "gpt-4o-mini"])
            try XCTAssertEqual(models[0].ownedBy, "openai")
        },

        MiniTest("J2 字符串数组格式") {
            let json = #"{"object":"list","data":["model-a","model-b"]}"#
            let models = try OpenAIClient.parseModels(Data(json.utf8))
            try XCTAssertEqual(models.map(\.id), ["model-a", "model-b"])
        },

        MiniTest("J3 顶层数组格式") {
            let json = #"[{"id":"m1"},{"id":"m2"}]"#
            let models = try OpenAIClient.parseModels(Data(json.utf8))
            try XCTAssertEqual(models.map(\.id), ["m1", "m2"])
        },

        MiniTest("J4 非法 JSON 抛出 invalidResponse") {
            try XCTAssertThrowsError(try OpenAIClient.parseModels(Data("not json".utf8))) { error in
                try XCTAssertEqual(error as? OpenAIError, .invalidResponse)
            }
        },

        MiniTest("J5 空 data 抛出 invalidResponse") {
            try XCTAssertThrowsError(try OpenAIClient.parseModels(Data("{\"data\":[]}".utf8)))
        },

        MiniTest("J6 通过客户端获取模型列表") {
            let transport = MockTransport(handlers: [
                "/v1/models": .json(#"{"data":[{"id":"gpt-4o"},{"id":"o3-mini"}]}"#)
            ])
            let client = OpenAIClient(transport: transport)
            let models = try await client.fetchModels(baseURL: "https://api.openai.com", apiKey: "sk-test")
            try XCTAssertEqual(models.count, 2)
            try XCTAssertEqual(models.first?.id, "gpt-4o")
            try XCTAssertEqual(transport.lastRequest?.method, "GET")
        },

        MiniTest("J7 模型列表接口报错时抛出 httpError") {
            let transport = MockTransport(handlers: ["/v1/models": .error("Unauthorized", status: 401)])
            let client = OpenAIClient(transport: transport)
            do {
                _ = try await client.fetchModels(baseURL: "https://api.openai.com", apiKey: "bad")
                try XCTFail("应当抛出错误")
            } catch let error as OpenAIError {
                try XCTAssertEqual(error, .httpError(status: 401, body: "{\"error\":{\"message\":\"Unauthorized\"}}"))
            }
        }
    ]
}
