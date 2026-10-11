import Foundation
import Network
import LLMDebuggerCore

/// 极简本地 HTTP 服务端，用于验证真实的 `URLSession` 流式读取路径
final class TestHTTPServer: @unchecked Sendable {
    typealias Responder = @Sendable (String) -> MockHTTPResponse

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.llmdebugger.testserver")
    private let responder: Responder
    private var connections: [NWConnection] = []

    init(responder: @escaping Responder) throws {
        self.responder = responder
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        self.listener = try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: 0)!)
        self.listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener.start(queue: queue)
    }

    /// 等待系统分配端口
    func port() async throws -> UInt16 {
        for _ in 0..<300 {
            if let port = listener.port?.rawValue, port != 0 {
                return port
            }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        throw OpenAIError.invalidResponse
    }

    func stop() {
        listener.cancel()
        for connection in connections { connection.cancel() }
        connections.removeAll()
    }

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        readRequest(connection, accumulated: Data())
    }

    private func readRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, _, error in
            guard let self else { return }
            var buffer = accumulated
            if let data { buffer.append(data) }

            let text = String(data: buffer, encoding: .utf8) ?? ""
            if text.range(of: "\r\n\r\n") == nil && error == nil {
                self.readRequest(connection, accumulated: buffer)
                return
            }

            let path = Self.path(from: text)
            let mock = self.responder(path)
            self.sendResponse(connection, mock: mock)
        }
    }

    private static func path(from requestText: String) -> String {
        let firstLine = requestText.split(separator: "\r\n").first ?? ""
        let parts = firstLine.split(separator: " ")
        if parts.count >= 2 { return String(parts[1]) }
        return "/"
    }

    private func sendResponse(_ connection: NWConnection, mock: MockHTTPResponse) {
        var head = "HTTP/1.1 \(mock.status) OK\r\n"
        for (key, value) in mock.headers {
            head += "\(key): \(value)\r\n"
        }
        head += "Connection: close\r\n\r\n"

        connection.send(content: head.data(using: .utf8), completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.sendChunks(connection, chunks: mock.chunks, index: 0)
        })
    }

    private func sendChunks(_ connection: NWConnection, chunks: [Data], index: Int) {
        guard index < chunks.count else {
            connection.cancel()
            return
        }
        connection.send(content: chunks[index], completion: .contentProcessed { [weak self] error in
            guard let self, error == nil else {
                connection.cancel()
                return
            }
            self.sendChunks(connection, chunks: chunks, index: index + 1)
        })
    }
}
