import Foundation
import LLMDebuggerCore

/// 用例组 B：SSE 增量解析
@MainActor
func sseParserTests() -> [MiniTest] {
    [
        MiniTest("B1 单个完整事件") {
            var parser = SSEParser()
            let events = parser.append("data: {\"a\":1}\n\n")
            try XCTAssertEqual(events.count, 1)
            try XCTAssertEqual(events.first?.data, "{\"a\":1}")
        },

        MiniTest("B2 一个 chunk 内多个事件") {
            var parser = SSEParser()
            let events = parser.append("data: 1\n\ndata: 2\n\ndata: 3\n\n")
            try XCTAssertEqual(events.map(\.data), ["1", "2", "3"])
        },

        MiniTest("B3 事件被切分到多个 chunk") {
            var parser = SSEParser()
            try XCTAssertTrue(parser.append("data: hello").isEmpty)
            try XCTAssertTrue(parser.append(" world\n").isEmpty)
            let events = parser.append("\ndata: bye\n\n")
            try XCTAssertEqual(events.map(\.data), ["hello world", "bye"])
        },

        MiniTest("B4 按字节切分也能正确解析") {
            var parser = SSEParser()
            let payload = "data: {\"a\":1}\n\n"
            var collected: [SSEEvent] = []
            for byte in Array(payload.utf8) {
                collected += parser.append(Data([byte]))
            }
            try XCTAssertEqual(collected.count, 1)
            try XCTAssertEqual(collected.first?.data, "{\"a\":1}")
        },

        MiniTest("B5 CRLF 分隔符") {
            var parser = SSEParser()
            let events = parser.append("data: first\r\n\r\ndata: second\r\n\r\n")
            try XCTAssertEqual(events.map(\.data), ["first", "second"])
        },

        MiniTest("B6 CR 分隔符") {
            var parser = SSEParser()
            let events = parser.append("data: first\r\rdata: second\r\r")
            try XCTAssertEqual(events.map(\.data), ["first", "second"])
        },

        MiniTest("B7 DONE 标记") {
            var parser = SSEParser()
            let events = parser.append("data: [DONE]\n\n")
            try XCTAssertEqual(events.count, 1)
            try XCTAssertTrue(events[0].isDone)
        },

        MiniTest("B8 多行 data 会被拼接") {
            var parser = SSEParser()
            let events = parser.append("data: line1\ndata: line2\n\n")
            try XCTAssertEqual(events.count, 1)
            try XCTAssertEqual(events[0].data, "line1\nline2")
        },

        MiniTest("B9 event 与 id 字段被解析") {
            var parser = SSEParser()
            let events = parser.append("id: 42\nevent: message\ndata: payload\n\n")
            try XCTAssertEqual(events[0].id, "42")
            try XCTAssertEqual(events[0].event, "message")
            try XCTAssertEqual(events[0].data, "payload")
        },

        MiniTest("B10 注释心跳被忽略") {
            var parser = SSEParser()
            let events = parser.append(": ping\n\ndata: real\n\n")
            try XCTAssertEqual(events.map(\.data), ["real"])
        },

        MiniTest("B11 中文被字节边界切断不乱码") {
            var parser = SSEParser()
            let payload = "data: 你好世界\n\n"
            let bytes = Array(payload.utf8)
            let mid = bytes.count / 2
            var collected: [SSEEvent] = []
            collected += parser.append(Data(bytes[0..<mid]))
            collected += parser.append(Data(bytes[mid...]))
            try XCTAssertEqual(collected.count, 1)
            try XCTAssertEqual(collected[0].data, "你好世界")
        },

        MiniTest("B12 emoji 被字节边界切断不乱码") {
            var parser = SSEParser()
            let payload = "data: 🎉👍\n\n"
            let bytes = Array(payload.utf8)
            var collected: [SSEEvent] = []
            for index in stride(from: 0, to: bytes.count, by: 3) {
                let end = min(index + 3, bytes.count)
                collected += parser.append(Data(bytes[index..<end]))
            }
            try XCTAssertEqual(collected.count, 1)
            try XCTAssertEqual(collected[0].data, "🎉👍")
        },

        MiniTest("B13 流末尾无分隔符时 finish 能吐出残留") {
            var parser = SSEParser()
            try XCTAssertTrue(parser.append("data: tail").isEmpty)
            let events = parser.finish()
            try XCTAssertEqual(events.count, 1)
            try XCTAssertEqual(events[0].data, "tail")
        },

        MiniTest("B14 data 后无空格也能解析") {
            var parser = SSEParser()
            let events = parser.append("data:{\"a\":1}\n\n")
            try XCTAssertEqual(events[0].data, "{\"a\":1}")
        },

        MiniTest("B15 不带 data 前缀的裸 JSON 也能兜底解析") {
            var parser = SSEParser()
            let events = parser.append("{\"choices\":[]}\n\n")
            try XCTAssertEqual(events.count, 1)
            try XCTAssertEqual(events[0].data, "{\"choices\":[]}")
        },

        MiniTest("B16 空数据块产生空 data 事件") {
            var parser = SSEParser()
            let events = parser.append("data: \n\n")
            try XCTAssertEqual(events.count, 1)
            try XCTAssertEqual(events[0].data, "")
        },

        MiniTest("B17 finish 之后缓冲区被清空") {
            var parser = SSEParser()
            _ = parser.append("data: x")
            _ = parser.finish()
            try XCTAssertTrue(parser.finish().isEmpty)
        },

        MiniTest("B18 混合 CRLF 与 LF 的连续流") {
            var parser = SSEParser()
            let payload = "data: 1\r\n\r\ndata: 2\n\ndata: 3\r\n\r\n"
            var collected: [SSEEvent] = []
            for chunk in splitIntoChunks(payload, size: 5) {
                collected += parser.append(chunk)
            }
            try XCTAssertEqual(collected.map(\.data), ["1", "2", "3"])
        },

        MiniTest("B19 超长无分隔符数据不会无限缓冲") {
            var parser = SSEParser()
            parser.maxBufferBytes = 64
            let long = String(repeating: "x", count: 200)
            let events = parser.append("data: " + long)
            try XCTAssertEqual(events.count, 1, "超过阈值后应强制产出一个事件")
        },

        MiniTest("B20 多个 chunk 拼接后的完整 OpenAI 流") {
            var parser = SSEParser()
            let payload = """
            data: {"choices":[{"delta":{"content":"你"}}]}

            data: {"choices":[{"delta":{"content":"好"}}]}

            data: [DONE]

            """
            var collected: [SSEEvent] = []
            for chunk in splitIntoChunks(payload, size: 17) {
                collected += parser.append(chunk)
            }
            collected += parser.finish()
            try XCTAssertEqual(collected.count, 3)
            try XCTAssertTrue(collected.last?.isDone == true)
        }
    ]
}

func splitIntoChunks(_ text: String, size: Int) -> [Data] {
    let bytes = Array(text.utf8)
    var result: [Data] = []
    var index = 0
    while index < bytes.count {
        let end = min(index + size, bytes.count)
        result.append(Data(bytes[index..<end]))
        index = end
    }
    return result
}
