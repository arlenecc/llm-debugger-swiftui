import Foundation
import LLMDebuggerCore

/// 用例组 A：服务地址归一化
@MainActor
func endpointResolverTests() -> [MiniTest] {
    [
        MiniTest("A1 裸域名自动补全 https 并追加 v1") {
            let result = try EndpointResolver.resolve("api.openai.com")
            try XCTAssertEqual(result.baseURL.absoluteString, "https://api.openai.com/v1")
            try XCTAssertEqual(result.modelsURL.absoluteString, "https://api.openai.com/v1/models")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://api.openai.com/v1/chat/completions")
        },

        MiniTest("A2 带 https 的域名追加 v1") {
            let result = try EndpointResolver.resolve("https://api.openai.com")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://api.openai.com/v1/chat/completions")
        },

        MiniTest("A3 尾斜杠不影响结果") {
            let a = try EndpointResolver.resolve("https://api.openai.com/")
            let b = try EndpointResolver.resolve("https://api.openai.com")
            try XCTAssertEqual(a.baseURL, b.baseURL)
        },

        MiniTest("A4 已带 v1 不重复追加") {
            let result = try EndpointResolver.resolve("https://api.openai.com/v1")
            try XCTAssertEqual(result.baseURL.absoluteString, "https://api.openai.com/v1")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://api.openai.com/v1/chat/completions")
        },

        MiniTest("A5 带前缀路径的版本目录保持") {
            let result = try EndpointResolver.resolve("https://openrouter.ai/api/v1")
            try XCTAssertEqual(result.modelsURL.absoluteString, "https://openrouter.ai/api/v1/models")
        },

        MiniTest("A6 粘贴完整 chat/completions 地址会剥离端点") {
            let result = try EndpointResolver.resolve("https://api.openai.com/v1/chat/completions")
            try XCTAssertEqual(result.baseURL.absoluteString, "https://api.openai.com/v1")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://api.openai.com/v1/chat/completions")
        },

        MiniTest("A7 粘贴 models 地址会剥离端点") {
            let result = try EndpointResolver.resolve("https://api.openai.com/v1/models")
            try XCTAssertEqual(result.baseURL.absoluteString, "https://api.openai.com/v1")
        },

        MiniTest("A8 本地 http 服务保持原样") {
            let result = try EndpointResolver.resolve("http://localhost:11434/v1")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString, "http://localhost:11434/v1/chat/completions")
        },

        MiniTest("A9 本地服务无版本段时追加版本") {
            let result = try EndpointResolver.resolve("http://127.0.0.1:8000")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString, "http://127.0.0.1:8000/v1/chat/completions")
        },

        MiniTest("A10 自定义版本路径") {
            let result = try EndpointResolver.resolve("https://example.com", versionPath: "v2")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://example.com/v2/chat/completions")
        },

        MiniTest("A11 空版本路径不追加") {
            let result = try EndpointResolver.resolve("https://example.com/openai", versionPath: "")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString, "https://example.com/openai/chat/completions")
        },

        MiniTest("A12 空地址抛出 empty") {
            try XCTAssertThrowsError(try EndpointResolver.resolve("   ")) { error in
                try XCTAssertEqual(error as? EndpointError, .empty)
            }
        },

        MiniTest("A13 非法地址抛出 invalid") {
            try XCTAssertThrowsError(try EndpointResolver.resolve("ftp://whatever")) { error in
                try XCTAssertEqual(error as? EndpointError, .invalid("ftp://whatever"))
            }
        },

        MiniTest("A14 带端口与子路径") {
            let result = try EndpointResolver.resolve("https://gateway.example.com:8443/proxy/openai/v1")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString,
                               "https://gateway.example.com:8443/proxy/openai/v1/chat/completions")
        },

        MiniTest("A15 忽略查询串与锚点") {
            let result = try EndpointResolver.resolve("https://api.openai.com?foo=bar#x")
            try XCTAssertEqual(result.baseURL.absoluteString, "https://api.openai.com/v1")
        },

        MiniTest("A16 v1beta 等版本段被识别") {
            let result = try EndpointResolver.resolve("https://generativelanguage.googleapis.com/v1beta")
            try XCTAssertEqual(result.chatCompletionsURL.absoluteString,
                               "https://generativelanguage.googleapis.com/v1beta/chat/completions")
        }
    ]
}
