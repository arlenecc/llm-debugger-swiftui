import Foundation

// MARK: - 传输层抽象

public struct TransportResponse: Sendable {
    public let response: HTTPURLResponse
    /// 响应体字节流（不是一次性读完，保证真正的流式）
    public let bytes: AsyncThrowingStream<UInt8, Error>

    public init(response: HTTPURLResponse, bytes: AsyncThrowingStream<UInt8, Error>) {
        self.response = response
        self.bytes = bytes
    }
}

public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> TransportResponse
    /// 主动取消当前所有进行中的请求（用于“停止生成”），尽快释放底层 TCP 连接。
    func cancelActiveRequests()
}

// MARK: - 基于 URLSession 的实现

public struct URLSessionTransport: HTTPTransport {
    private let manager: SessionManager

    public init(session: URLSession = URLSessionTransport.makeDefaultSession()) {
        self.manager = SessionManager(session: session)
    }

    public func send(_ request: URLRequest) async throws -> TransportResponse {
        try await manager.send(request)
    }

    public func cancelActiveRequests() {
        manager.cancel()
    }

    public static func makeDefaultSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120
        configuration.timeoutIntervalForResource = 60 * 10
        configuration.httpMaximumConnectionsPerHost = 4
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }
}

/// 持有可失效的 `URLSession`：`cancel()` 会让当前会话失效（取消在途请求/连接），
/// 并为下一次请求新建会话，避免复用被失效的会话。
private final class SessionManager: @unchecked Sendable {
    private let lock = NSLock()
    private var session: URLSession

    init(session: URLSession) {
        self.session = session
    }

    func send(_ request: URLRequest) async throws -> TransportResponse {
        lock.lock()
        let session = self.session
        lock.unlock()
        let (asyncBytes, response) = try await session.bytes(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenAIError.invalidResponse
        }

        // 用 Box 持有 continuation，避免 `continuation ↔ 内部读取任务` 的强引用环：
        // 任务只强引用 Box，Box 在任务结束时清空 continuation，从而流被消费方丢弃后能正常释放。
        let box = ContinuationBox()
        let stream = AsyncThrowingStream(UInt8.self, bufferingPolicy: .unbounded) { continuation in
            box.continuation = continuation
            let task = Task {
                do {
                    var iterator = asyncBytes.makeAsyncIterator()
                    while let byte = try await iterator.next() {
                        box.continuation?.yield(byte)
                    }
                    box.continuation?.finish()
                } catch {
                    box.continuation?.finish(throwing: error)
                }
                box.continuation = nil
            }
            continuation.onTermination = { _ in task.cancel() }
        }

        return TransportResponse(response: httpResponse, bytes: stream)
    }

    func cancel() {
        let old: URLSession
        lock.lock()
        old = session
        session = URLSessionTransport.makeDefaultSession()
        lock.unlock()
        old.invalidateAndCancel()
    }
}

/// 桥接 continuation 的中转盒，用于在任务生命周期内持有 continuation 但可被清空，
/// 从而打破 continuation 与任务之间的强引用环。
private final class ContinuationBox: @unchecked Sendable {
    var continuation: AsyncThrowingStream<UInt8, Error>.Continuation?
}
