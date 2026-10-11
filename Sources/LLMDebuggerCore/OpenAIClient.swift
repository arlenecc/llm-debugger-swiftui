import Foundation

// MARK: - 请求参数

public struct ChatParameters: Equatable, Sendable {
    public var model: String
    public var temperature: Double?
    public var topP: Double?
    public var maxTokens: Int?
    /// 是否在流式请求里附带 `stream_options.include_usage`
    public var includeUsage: Bool
    /// 是否把 `content` 中的 `<think>` 段落识别为思考过程
    public var routeThinkTags: Bool

    public init(model: String,
                temperature: Double? = 0.7,
                topP: Double? = nil,
                maxTokens: Int? = nil,
                includeUsage: Bool = true,
                routeThinkTags: Bool = true) {
        self.model = model
        self.temperature = temperature
        self.topP = topP
        self.maxTokens = maxTokens
        self.includeUsage = includeUsage
        self.routeThinkTags = routeThinkTags
    }
}

// MARK: - 客户端

public final class OpenAIClient: @unchecked Sendable {
    public let transport: HTTPTransport
    private let logger: WireLogger?

    /// 单条 SSE 原始行写入日志时的最大长度，避免超大 chunk 刷屏
    public var maxLoggedLineLength = 2000

    public init(transport: HTTPTransport, logger: WireLogger? = nil) {
        self.transport = transport
        self.logger = logger
    }

    // MARK: 模型列表

    public func makeModelsRequest(baseURL: String, apiKey: String, versionPath: String = "v1") throws -> URLRequest {
        let endpoints = try EndpointResolver.resolve(baseURL, versionPath: versionPath)
        var request = URLRequest(url: endpoints.modelsURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 30
        return request
    }

    public func fetchModels(baseURL: String, apiKey: String, versionPath: String = "v1") async throws -> [ModelInfo] {
        let request = try makeModelsRequest(baseURL: baseURL, apiKey: apiKey, versionPath: versionPath)
        log(.request, "GET \(request.url?.absoluteString ?? "")\n" + headerDescription(request))

        let response = try await transport.send(request)
        log(.response, "HTTP \(response.response.statusCode)\n" + responseHeaderDescription(response.response))

        let data = try await collect(response.bytes)
        guard (200..<300).contains(response.response.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            log(.error, "获取模型列表失败：HTTP \(response.response.statusCode)\n\(body)")
            throw OpenAIError.httpError(status: response.response.statusCode, body: body)
        }

        log(.response, "模型列表响应 (\(data.count) bytes)\n\(prettyJSON(data) ?? (String(data: data, encoding: .utf8) ?? ""))")
        return try Self.parseModels(data)
    }

    public static func parseModels(_ data: Data) throws -> [ModelInfo] {
        guard let json = try? JSONSerialization.jsonObject(with: data) else {
            throw OpenAIError.invalidResponse
        }

        if let object = json as? [String: Any], let list = object["data"] {
            if let dicts = list as? [[String: Any]] {
                let models = dicts.compactMap { dict -> ModelInfo? in
                    guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
                    return ModelInfo(id: id, ownedBy: dict["owned_by"] as? String)
                }
                if !models.isEmpty { return models }
            }
            if let strings = list as? [String] {
                let models = strings.filter { !$0.isEmpty }.map { ModelInfo(id: $0) }
                if !models.isEmpty { return models }
            }
        }

        // 极少数实现直接返回数组
        if let array = json as? [[String: Any]] {
            let models = array.compactMap { dict -> ModelInfo? in
                guard let id = dict["id"] as? String, !id.isEmpty else { return nil }
                return ModelInfo(id: id, ownedBy: dict["owned_by"] as? String)
            }
            if !models.isEmpty { return models }
        }
        if let array = json as? [String] {
            let models = array.filter { !$0.isEmpty }.map { ModelInfo(id: $0) }
            if !models.isEmpty { return models }
        }

        throw OpenAIError.invalidResponse
    }

    // MARK: 对话（流式）

    public static func makeChatRequestBody(messages: [WireMessage], parameters: ChatParameters) -> Data {
        var body: [String: Any] = [
            "model": parameters.model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true
        ]
        if parameters.includeUsage {
            body["stream_options"] = ["include_usage": true]
        }
        if let temperature = parameters.temperature {
            body["temperature"] = temperature
        }
        if let topP = parameters.topP {
            body["top_p"] = topP
        }
        if let maxTokens = parameters.maxTokens {
            body["max_tokens"] = maxTokens
        }
        return (try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    public func makeChatRequest(baseURL: String,
                                apiKey: String,
                                messages: [WireMessage],
                                parameters: ChatParameters,
                                versionPath: String = "v1") throws -> URLRequest {
        let endpoints = try EndpointResolver.resolve(baseURL, versionPath: versionPath)
        var request = URLRequest(url: endpoints.chatCompletionsURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
        request.timeoutInterval = 120
        request.httpBody = Self.makeChatRequestBody(messages: messages, parameters: parameters)
        return request
    }

    /// 发起一次流式对话。返回的流会持续产出 `StreamEvent`，调用方在结束时会收到 `finish`。
    public func streamChat(baseURL: String,
                           apiKey: String,
                           messages: [WireMessage],
                           parameters: ChatParameters,
                           versionPath: String = "v1") -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream<StreamEvent, Error>(bufferingPolicy: .unbounded) { continuation in
            let box = StreamContinuationBox()
            box.continuation = continuation
            let task = Task { [self] in
                do {
                    let request = try makeChatRequest(baseURL: baseURL,
                                                      apiKey: apiKey,
                                                      messages: messages,
                                                      parameters: parameters,
                                                      versionPath: versionPath)
                    let bodyText = String(data: request.httpBody ?? Data(), encoding: .utf8) ?? ""
                    log(.request, "POST \(request.url?.absoluteString ?? "")\n\(headerDescription(request))\n\(bodyText)")

                    let response = try await transport.send(request)
                    log(.response, "HTTP \(response.response.statusCode)\n\(responseHeaderDescription(response.response))")

                    let status = response.response.statusCode
                    guard (200..<300).contains(status) else {
                        let body = String(data: try await collect(response.bytes), encoding: .utf8) ?? ""
                        log(.error, "HTTP \(status)\n\(body)")
                        if let message = Self.extractErrorMessage(body) {
                            box.continuation?.finish(throwing: OpenAIError.serverMessage(message))
                        } else {
                            box.continuation?.finish(throwing: OpenAIError.httpError(status: status, body: body))
                        }
                        return
                    }

                    let contentType = response.response.value(forHTTPHeaderField: "Content-Type") ?? ""
                    if !contentType.localizedCaseInsensitiveContains("event-stream") {
                        // 服务端忽略了 stream 参数，直接返回完整 JSON
                        let data = try await collect(response.bytes)
                        let text = String(data: data, encoding: .utf8) ?? ""
                        log(.stream, "非 SSE 响应，按完整 JSON 处理：\n\(truncate(text))")
                        let decoder = ChunkDecoder(routeThinkTags: parameters.routeThinkTags)
                        do {
                            if let event = try decoder.decode(text) { box.continuation?.yield(event) }
                            if let tail = decoder.finish() { box.continuation?.yield(tail) }
                        } catch {
                            log(.error, error.localizedDescription)
                        }
                        box.continuation?.finish()
                        return
                    }

                    let decoder = ChunkDecoder(routeThinkTags: parameters.routeThinkTags)
                    var parser = SSEParser()
                    var buffer = [UInt8]()
                    buffer.reserveCapacity(1024)

                    for try await byte in response.bytes {
                        if Task.isCancelled { break }
                        buffer.append(byte)
                        if buffer.count >= 512 {
                            let events = parser.append(buffer)
                            buffer.removeAll(keepingCapacity: true)
                            handle(events: events, decoder: decoder, continuation: box.continuation)
                        }
                    }

                    if Task.isCancelled {
                        log(.info, "连接已中断（取消请求）")
                        box.continuation?.finish(throwing: CancellationError())
                        return
                    }

                    if !buffer.isEmpty {
                        let events = parser.append(buffer)
                        buffer.removeAll(keepingCapacity: true)
                        handle(events: events, decoder: decoder, continuation: box.continuation)
                    }
                    handle(events: parser.finish(), decoder: decoder, continuation: box.continuation)

                    if let tail = decoder.finish() {
                        box.continuation?.yield(tail)
                    }
                    log(.info, "SSE 流结束")
                    box.continuation?.finish()
                } catch {
                    if error is CancellationError {
                        log(.info, "请求已取消")
                    } else {
                        log(.error, "请求失败：\(error.localizedDescription)")
                    }
                    box.continuation?.finish(throwing: error)
                }
                box.continuation = nil
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: 内部实现

    private func handle(events: [SSEEvent],
                        decoder: ChunkDecoder,
                        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?) {
        for event in events {
            if event.isDone {
                log(.stream, "[DONE]")
                continue
            }
            log(.stream, truncate(event.data))
            do {
                if let decoded = try decoder.decode(event.data) {
                    continuation?.yield(decoded)
                }
            } catch {
                log(.error, error.localizedDescription)
            }
        }
    }

    private func collect(_ bytes: AsyncThrowingStream<UInt8, Error>) async throws -> Data {
        var data = Data()
        for try await byte in bytes {
            data.append(byte)
        }
        return data
    }

    private func truncate(_ text: String) -> String {
        if text.utf8.count <= maxLoggedLineLength { return text }
        let limit = maxLoggedLineLength
        var index = text.startIndex
        var count = 0
        while index < text.endIndex, count < limit {
            let scalar = text[index]
            count += scalar.utf8.count
            index = text.index(after: index)
        }
        return String(text[text.startIndex..<index]) + " …(已截断)"
    }

    private func log(_ level: LogLevel, _ message: String) {
        logger?.log(level, message)
    }

    private func headerDescription(_ request: URLRequest) -> String {
        var headers = request.allHTTPHeaderFields ?? [:]
        headers = Secrets.redactHeaders(headers)
        return headers
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private func responseHeaderDescription(_ response: HTTPURLResponse) -> String {
        let headers = response.allHeaderFields
        var lines: [String] = []
        for (key, value) in headers {
            lines.append("\(key): \(value)")
        }
        return lines.sorted().joined(separator: "\n")
    }

    private static func extractErrorMessage(_ body: String) -> String? {
        guard let data = body.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        if let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            return message
        }
        if let message = json["message"] as? String {
            return message
        }
        return nil
    }

    private func prettyJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              JSONSerialization.isValidJSONObject(object)
        else { return nil }
        guard let pretty = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: pretty, encoding: .utf8)
    }
}

/// 桥接 continuation 的中转盒：任务仅在生命周期内持有 continuation，并在结束时清空，
/// 从而打破 `continuation ↔ 内部任务` 的强引用环，流被丢弃后即可释放资源。
private final class StreamContinuationBox: @unchecked Sendable {
    var continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation?
}
