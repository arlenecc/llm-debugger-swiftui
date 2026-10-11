import Foundation
import LLMDebuggerCore

/// 测试用的内存传输层，可精确控制响应码、响应头与分块字节流
struct MockHTTPResponse: Sendable {
    var status: Int = 200
    var headers: [String: String] = ["Content-Type": "text/event-stream"]
    var chunks: [Data] = []
    /// 每个 chunk 之间的间隔，用于模拟真实网络节奏
    var chunkDelay: TimeInterval = 0
    /// 模拟传输层失败（例如断网），值为失败描述
    var transportErrorMessage: String?

    init(status: Int = 200,
         headers: [String: String] = ["Content-Type": "text/event-stream"],
         chunks: [Data] = [],
         chunkDelay: TimeInterval = 0,
         transportErrorMessage: String? = nil) {
        self.status = status
        self.headers = headers
        self.chunks = chunks
        self.chunkDelay = chunkDelay
        self.transportErrorMessage = transportErrorMessage
    }

    static func sse(_ lines: [String], chunkDelay: TimeInterval = 0) -> MockHTTPResponse {
        MockHTTPResponse(chunks: lines.map { Data($0.utf8) }, chunkDelay: chunkDelay)
    }

    static func json(_ text: String, status: Int = 200) -> MockHTTPResponse {
        MockHTTPResponse(
            status: status,
            headers: ["Content-Type": "application/json"],
            chunks: [Data(text.utf8)]
        )
    }

    static func error(_ message: String, status: Int = 500) -> MockHTTPResponse {
        json("{\"error\":{\"message\":\"\(message)\"}}", status: status)
    }
}

/// 传输层错误（Error 需要可发送，这里用字符串承载描述）
struct MockTransportError: Error, LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// 把加锁操作收敛到同步方法里，避免在 async 上下文中直接使用 NSLock
private final class MockState: @unchecked Sendable {
    typealias Record = (url: URL, method: String, headers: [String: String], body: Data?)

    private let lock = NSLock()
    private var handlers: [String: MockHTTPResponse]
    private var recorded: [Record] = []

    init(handlers: [String: MockHTTPResponse]) {
        self.handlers = handlers
    }

    func set(_ pathSuffix: String, _ response: MockHTTPResponse) {
        lock.lock()
        handlers[pathSuffix] = response
        lock.unlock()
    }

    func record(_ entry: Record) -> [String: MockHTTPResponse] {
        lock.lock()
        recorded.append(entry)
        let snapshot = handlers
        lock.unlock()
        return snapshot
    }

    var requests: [Record] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

final class MockTransport: HTTPTransport, @unchecked Sendable {
    private let state: MockState

    init(handlers: [String: MockHTTPResponse] = [:]) {
        self.state = MockState(handlers: handlers)
    }

    func set(_ pathSuffix: String, _ response: MockHTTPResponse) {
        state.set(pathSuffix, response)
    }

    var requests: [(url: URL, method: String, headers: [String: String], body: Data?)] {
        state.requests
    }

    var lastRequest: (url: URL, method: String, headers: [String: String], body: Data?)? {
        requests.last
    }

    func lastRequestBody() -> [String: Any]? {
        guard let data = lastRequest?.body else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    var requestCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> TransportResponse {
        let url = request.url ?? URL(string: "https://example.com")!
        let snapshot = state.record((url: url,
                                     method: request.httpMethod ?? "GET",
                                     headers: request.allHTTPHeaderFields ?? [:],
                                     body: request.httpBody))

        let path = url.path
        var mock: MockHTTPResponse?
        if let exact = snapshot[path] {
            mock = exact
        } else if let suffixMatch = snapshot.first(where: { key, _ in key != "*" && path.hasSuffix(key) }) {
            mock = suffixMatch.value
        } else {
            mock = snapshot["*"]
        }

        guard let mock else {
            return TransportResponse(
                response: Self.makeResponse(url: url, status: 404, headers: ["Content-Type": "application/json"]),
                bytes: Self.stream(of: [Data("{\"error\":{\"message\":\"not found\"}}".utf8)], delay: 0)
            )
        }

        if let message = mock.transportErrorMessage {
            throw MockTransportError(message: message)
        }

        let response = Self.makeResponse(url: url, status: mock.status, headers: mock.headers)
        return TransportResponse(response: response, bytes: Self.stream(of: mock.chunks, delay: mock.chunkDelay))
    }

    func cancelActiveRequests() {}

    private static func makeResponse(url: URL, status: Int, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
    }

    private static func stream(of chunks: [Data], delay: TimeInterval) -> AsyncThrowingStream<UInt8, Error> {
        AsyncThrowingStream(UInt8.self, bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                for chunk in chunks {
                    if Task.isCancelled { break }
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    }
                    for byte in chunk { continuation.yield(byte) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// 用于制造「永不结束」的流，验证取消逻辑
struct NeverEndingStreamTransport: HTTPTransport {
    let chunk: Data
    let chunkDelay: TimeInterval

    init(chunk: Data, chunkDelay: TimeInterval = 0.02) {
        self.chunk = chunk
        self.chunkDelay = chunkDelay
    }

    func send(_ request: URLRequest) async throws -> TransportResponse {
        let url = request.url ?? URL(string: "https://example.com")!
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        let stream = AsyncThrowingStream(UInt8.self, bufferingPolicy: .unbounded) { continuation in
            let task = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(chunkDelay * 1_000_000_000))
                    for byte in chunk { continuation.yield(byte) }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
        return TransportResponse(response: response, bytes: stream)
    }

    func cancelActiveRequests() {}
}
