import Foundation

// MARK: - SSE 增量解析

public struct SSEEvent: Equatable, Sendable {
    public let data: String
    public let event: String?
    public let id: String?

    public init(data: String, event: String? = nil, id: String? = nil) {
        self.data = data
        self.event = event
        self.id = id
    }

    public var isDone: Bool {
        data.trimmingCharacters(in: .whitespacesAndNewlines) == "[DONE]"
    }
}

/// 增量 SSE 解析器。
///
/// 设计要点：
/// - 只按**字节**查找分隔符，只有完整事件块才做 UTF-8 解码，
///   因此多字节字符（中文 / emoji）被 chunk 边界切开也不会乱码；
/// - 支持 `\n\n` / `\r\n\r\n` / `\r\r` 三种分隔符；
/// - `finish()` 会把流末尾没有分隔符的残留当作一个事件吐出；
/// - 兼容极少数服务端「不带 `data:` 前缀直接吐 JSON」的情况。
public struct SSEParser {
    /// 单个事件块的最大缓冲，超过且仍无分隔符时强制作为一个事件处理，防止无限增长
    public var maxBufferBytes: Int = 1 << 20

    private var buffer = Data()

    public init() {}

    public mutating func append(_ chunk: Data) -> [SSEEvent] {
        guard !chunk.isEmpty else { return [] }
        buffer.append(chunk)
        return drain(force: buffer.count >= maxBufferBytes)
    }

    public mutating func append(_ bytes: [UInt8]) -> [SSEEvent] {
        append(Data(bytes))
    }

    public mutating func append(_ text: String) -> [SSEEvent] {
        append(Data(text.utf8))
    }

    /// 流结束时调用，处理残留数据
    public mutating func finish() -> [SSEEvent] {
        defer { buffer.removeAll(keepingCapacity: true) }
        let trimmed = Self.trim(buffer)
        guard !trimmed.isEmpty else { return [] }
        return parse(block: trimmed)
    }

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
    }

    // MARK: 内部实现

    private mutating func drain(force: Bool) -> [SSEEvent] {
        var events: [SSEEvent] = []
        while true {
            guard let delimiter = Self.findDelimiter(in: buffer) else { break }
            let block = Data(buffer[buffer.startIndex..<(buffer.startIndex + delimiter.start)])
            buffer.removeSubrange(buffer.startIndex..<(buffer.startIndex + delimiter.end))
            events.append(contentsOf: parse(block: block))
        }

        if force && !buffer.isEmpty {
            let block = buffer
            buffer.removeAll(keepingCapacity: true)
            events.append(contentsOf: parse(block: block))
        }
        return events
    }

    /// 返回最早出现的空行分隔符范围，支持 `\n\n` / `\r\n\r\n` / `\r\r`
    private static func findDelimiter(in data: Data) -> (start: Int, end: Int)? {
        let n = data.count
        guard n >= 2 else { return nil }
        return data.withUnsafeBytes { raw -> (start: Int, end: Int)? in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 1 < n {
                let b = bytes[i]
                if b == 0x0A, bytes[i + 1] == 0x0A {
                    return (start: i, end: i + 2)          // \n\n
                }
                if b == 0x0D, bytes[i + 1] == 0x0D {
                    return (start: i, end: i + 2)          // \r\r
                }
                if b == 0x0D, i + 3 < n,
                   bytes[i + 1] == 0x0A, bytes[i + 2] == 0x0D, bytes[i + 3] == 0x0A {
                    return (start: i, end: i + 4)          // \r\n\r\n
                }
                i += 1
            }
            return nil
        }
    }

    private static func trim(_ data: Data) -> Data {
        var start = data.startIndex
        var end = data.endIndex
        let set: Set<UInt8> = [0x0A, 0x0D, 0x20, 0x09]
        while start < end, set.contains(data[start]) { start += 1 }
        while start < end, set.contains(data[end - 1]) { end -= 1 }
        return Data(data[start..<end])
    }

    private func parse(block: Data) -> [SSEEvent] {
        guard let text = String(data: block, encoding: .utf8) else { return [] }
        return parse(block: text)
    }

    private func parse(block text: String) -> [SSEEvent] {
        var dataLines: [String] = []
        var eventName: String?
        var eventID: String?
        var sawDataField = false

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.isEmpty { continue }
            if line.hasPrefix(":") { continue } // 注释 / 心跳

            guard let colon = line.firstIndex(of: ":") else { continue }
            let field = String(line[line.startIndex..<colon])
            var value = String(line[line.index(after: colon)...])
            if value.hasPrefix(" ") { value.removeFirst() }

            switch field {
            case "data":
                sawDataField = true
                dataLines.append(value)
            case "event":
                eventName = value
            case "id":
                eventID = value
            default:
                break
            }
        }

        if sawDataField {
            return [SSEEvent(data: dataLines.joined(separator: "\n"), event: eventName, id: eventID)]
        }

        // 兜底：没有 `data:` 字段但整块就是 JSON
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            return [SSEEvent(data: trimmed, event: nil, id: nil)]
        }
        return []
    }
}
