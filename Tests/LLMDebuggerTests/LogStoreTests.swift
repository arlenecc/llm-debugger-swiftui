import Foundation
import LLMDebuggerCore

/// 用例组 G：日志仓库
@MainActor
func logStoreTests() -> [MiniTest] {
    [
        MiniTest("G1 写入后 flush 可见") {
            let store = LogStore(capacity: 10, flushInterval: 0.05)
            store.append(.info, "hello")
            store.flush()
            try XCTAssertEqual(store.entries.count, 1)
            try XCTAssertEqual(store.entries[0].text, "hello")
            try XCTAssertEqual(store.entries[0].level, .info)
        },

        MiniTest("G2 flush 前不可见") {
            let store = LogStore(capacity: 10, flushInterval: 5)
            store.append(.info, "pending")
            try XCTAssertTrue(store.entries.isEmpty)
        },

        MiniTest("G3 容量上限被遵守") {
            let store = LogStore(capacity: 5, flushInterval: 0.05)
            for index in 0..<20 {
                store.append(.stream, "line-\(index)")
                store.flush()
            }
            try XCTAssertEqual(store.entries.count, 5)
            try XCTAssertEqual(store.entries.first?.text, "line-15")
            try XCTAssertEqual(store.entries.last?.text, "line-19")
        },

        MiniTest("G4 id 单调递增") {
            let store = LogStore(capacity: 100, flushInterval: 0.05)
            store.append(.info, "a")
            store.append(.info, "b")
            store.append(.info, "c")
            store.flush()
            let ids = store.entries.map(\.id)
            try XCTAssertEqual(ids, ids.sorted())
            try XCTAssertEqual(Set(ids).count, 3)
        },

        MiniTest("G5 clear 清空") {
            let store = LogStore(capacity: 10, flushInterval: 0.05)
            store.append(.info, "x")
            store.flush()
            store.clear()
            store.flush()
            try XCTAssertTrue(store.entries.isEmpty)
        },

        MiniTest("G6 多线程并发写入不丢条目") {
            let store = LogStore(capacity: 10000, flushInterval: 0.05)
            let perThread = 64
            let threads = 8
            let expected = perThread * threads
            DispatchQueue.concurrentPerform(iterations: threads) { _ in
                for _ in 0..<perThread {
                    store.append(.stream, "tick")
                }
            }
            store.flushAndWait()
            try XCTAssertEqual(store.entries.count, expected)
        },

        MiniTest("G7 异步自动 flush 会生效") {
            let store = LogStore(capacity: 100, flushInterval: 0.02)
            store.append(.info, "auto")
            try? await Task.sleep(nanoseconds: 150_000_000)
            try XCTAssertEqual(store.entries.count, 1)
        },

        MiniTest("G8 所有级别都能写入") {
            let store = LogStore(capacity: 100, flushInterval: 0.05)
            for level in LogLevel.allCases {
                store.append(level, level.rawValue)
            }
            store.flush()
            try XCTAssertEqual(Set(store.entries.map(\.level)).count, LogLevel.allCases.count)
        }
    ]
}

/// 用例组 H：密钥脱敏
@MainActor
func secretsTests() -> [MiniTest] {
    [
        MiniTest("H1 长密钥保留前后缀") {
            try XCTAssertEqual(Secrets.mask("sk-abcdefghijklmnop"), "sk-***mnop")
        },

        MiniTest("H2 短密钥全部打码") {
            try XCTAssertEqual(Secrets.mask("abc"), "***")
            try XCTAssertEqual(Secrets.mask("12345678"), "********")
        },

        MiniTest("H3 空值返回空") {
            try XCTAssertEqual(Secrets.mask(""), "")
        },

        MiniTest("H4 authorization 头被脱敏且不泄露完整密钥") {
            let headers = ["Authorization": "Bearer sk-1234567890abcdef",
                           "Content-Type": "application/json"]
            let redacted = Secrets.redactHeaders(headers)
            try XCTAssertEqual(redacted["Content-Type"], "application/json")
            try XCTAssertFalse(redacted["Authorization"]!.contains("1234567890abcdef"))
            try XCTAssertTrue(redacted["Authorization"]!.hasPrefix("Bearer "))
        },

        MiniTest("H5 各种 apikey 头都被脱敏") {
            let headers = ["x-api-key": "secret-key-value",
                           "api-key": "another-secret-value",
                           "openai-api-key": "yet-another-secret"]
            let redacted = Secrets.redactHeaders(headers)
            try XCTAssertFalse(redacted["x-api-key"]!.contains("secret-key-value"))
            try XCTAssertFalse(redacted["api-key"]!.contains("another-secret-value"))
            try XCTAssertFalse(redacted["openai-api-key"]!.contains("yet-another-secret"))
        },

        MiniTest("H6 文本兜底替换") {
            let secret = "sk-1234567890abcdef"
            let text = "Authorization: Bearer \(secret)"
            let redacted = Secrets.redact(text, secret: secret)
            try XCTAssertFalse(redacted.contains(secret))
        }
    ]
}
