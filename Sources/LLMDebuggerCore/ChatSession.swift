import Foundation
import Combine

// MARK: - 会话中的一条消息

@MainActor
public final class MessageItem: ObservableObject, Identifiable {
    public let id: UUID
    public let role: ChatRole
    public let createdAt: Date

    @Published public private(set) var content: String
    @Published public private(set) var thinking: String
    @Published public private(set) var isStreaming: Bool
    @Published public private(set) var errorMessage: String?

    public init(id: UUID = UUID(),
                role: ChatRole,
                content: String = "",
                thinking: String = "",
                isStreaming: Bool = false) {
        self.id = id
        self.role = role
        self.content = content
        self.thinking = thinking
        self.isStreaming = isStreaming
        self.createdAt = Date()
    }

    func append(content text: String) {
        guard !text.isEmpty else { return }
        content += text
    }

    func append(thinking text: String) {
        guard !text.isEmpty else { return }
        thinking += text
    }

    func setStreaming(_ value: Bool) {
        isStreaming = value
    }

    func setError(_ message: String?) {
        errorMessage = message
    }

    /// 供异常中断时补一段提示
    func appendSuffix(_ text: String) {
        content += text
    }
}

// MARK: - 会话引擎

/// 流式输出期间在后台线程累积文本，主线程按节流节奏取走，避免每收到一个 token 都触发 SwiftUI 刷新
private final class StreamBuffer {
    private(set) var thinking = ""
    private(set) var answer = ""

    func add(thinking: String = "", answer: String = "") {
        if !thinking.isEmpty { self.thinking += thinking }
        if !answer.isEmpty { self.answer += answer }
    }

    func take() -> (thinking: String, answer: String) {
        let result = (thinking, answer)
        thinking = ""
        answer = ""
        return result
    }

    var pendingCount: Int { thinking.utf8.count + answer.utf8.count }
}

/// 需要持久化的配置项快照
private struct ConfigSnapshot {
    var baseURL: String
    var apiKey: String
    var model: String
    var versionPath: String
    var systemPrompt: String
    var temperature: Double
    var maxTokens: Int?
    var includeUsage: Bool
    var routeThinkTags: Bool
}

@MainActor
public final class ChatSession: ObservableObject {
    // MARK: 配置

    @Published public var baseURL: String { didSet { persist() } }
    @Published public var apiKey: String { didSet { persist() } }
    @Published public var model: String { didSet { persist() } }
    @Published public var versionPath: String { didSet { persist() } }
    @Published public var systemPrompt: String { didSet { persist() } }
    @Published public var temperature: Double { didSet { persist() } }
    @Published public var maxTokens: Int? { didSet { persist() } }
    @Published public var includeUsage: Bool { didSet { persist() } }
    @Published public var routeThinkTags: Bool { didSet { persist() } }

    // MARK: 状态

    @Published public private(set) var messages: [MessageItem] = []
    @Published public private(set) var models: [ModelInfo] = []
    @Published public private(set) var isFetchingModels = false
    @Published public private(set) var isStreaming = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var usage: UsageInfo?
    @Published public private(set) var modelsError: String?
    /// 手动选中要查看思考过程的消息；nil 表示跟随最新一条
    @Published public var selectedMessageID: UUID?
    /// 流式刷新计数器：每次主线程提交增量时 +1，供视图层驱动「自动滚动」等跟随行为
    @Published public private(set) var streamTick: Int = 0

    public let logs: LogStore
    public let meter = ThroughputMeter()

    private let client: OpenAIClient
    private let transport: HTTPTransport
    private let persistence: Persistence

    private var activeTask: Task<Void, Never>?

    /// 主线程刷新流式文本的节流间隔
    public var streamFlushInterval: TimeInterval = 0.05

    deinit {
        activeTask?.cancel()
    }

    /// 当前是否允许发送（供 UI 禁用发送按钮）
    public var canSend: Bool {
        let modelReady = !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let urlReady = (try? EndpointResolver.resolve(baseURL, versionPath: versionPath)) != nil
        return !isStreaming && modelReady && urlReady
    }

    public init(transport: HTTPTransport = URLSessionTransport(),
                logger: LogStore = LogStore(),
                persist: Bool = true) {
        self.transport = transport
        self.logs = logger
        self.client = OpenAIClient(transport: transport, logger: logger)
        self.persistence = Persistence(enabled: persist)

        let saved = persistence.load()
        self.baseURL = saved.baseURL
        self.apiKey = saved.apiKey
        self.model = saved.model
        self.versionPath = saved.versionPath
        self.systemPrompt = saved.systemPrompt
        self.temperature = saved.temperature
        self.maxTokens = saved.maxTokens
        self.includeUsage = saved.includeUsage
        self.routeThinkTags = saved.routeThinkTags
    }

    // MARK: 派生数据

    public var displayedThinking: String {
        if let id = selectedMessageID,
           let message = messages.first(where: { $0.id == id }),
           message.role == .assistant {
            return message.thinking
        }
        return messages.last(where: { $0.role == .assistant })?.thinking ?? ""
    }

    public var currentParameters: ChatParameters {
        ChatParameters(
            model: model,
            temperature: temperature,
            topP: nil,
            maxTokens: maxTokens,
            includeUsage: includeUsage,
            routeThinkTags: routeThinkTags
        )
    }

    // MARK: 模型列表

    public func refreshModels() async {
        guard !isFetchingModels else { return }
        isFetchingModels = true
        modelsError = nil
        logs.append(.info, "开始获取模型列表…")

        let baseURL = self.baseURL
        let apiKey = self.apiKey
        let versionPath = self.versionPath

        do {
            let list = try await client.fetchModels(baseURL: baseURL, apiKey: apiKey, versionPath: versionPath)
            models = list
            logs.append(.info, "获取到 \(list.count) 个模型")
            if model.isEmpty, let first = list.first {
                model = first.id
            }
        } catch {
            modelsError = error.localizedDescription
            lastError = error.localizedDescription
            logs.append(.error, "获取模型列表失败：\(error.localizedDescription)")
        }
        isFetchingModels = false
    }

    // MARK: 发送消息

    public func send(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !isStreaming else {
            logs.append(.info, "正在生成中，请先停止或等待完成")
            return
        }

        guard !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            lastError = "请先填写或获取模型名称"
            logs.append(.error, "模型名称为空，已取消发送")
            return
        }

        do {
            _ = try EndpointResolver.resolve(baseURL, versionPath: versionPath)
        } catch {
            lastError = error.localizedDescription
            logs.append(.error, error.localizedDescription)
            return
        }

        lastError = nil
        selectedMessageID = nil
        usage = nil
        meter.reset()

        let userMessage = MessageItem(role: .user, content: trimmed)
        let assistant = MessageItem(role: .assistant, content: "", thinking: "", isStreaming: true)
        messages.append(userMessage)
        messages.append(assistant)

        let wire = buildWireMessages()
        let parameters = currentParameters
        let baseURL = self.baseURL
        let apiKey = self.apiKey
        let versionPath = self.versionPath

        isStreaming = true

        let flushInterval = streamFlushInterval
        activeTask = Task.detached(priority: .userInitiated) { [weak self] in
            await self?.runStream(
                baseURL: baseURL,
                apiKey: apiKey,
                versionPath: versionPath,
                messages: wire,
                parameters: parameters,
                assistant: assistant,
                flushInterval: flushInterval
            )
        }
    }

    public func stop() {
        guard isStreaming else { return }
        logs.append(.info, "用户停止生成")
        activeTask?.cancel()
        // 立即作废底层连接，避免“停止”后服务端仍在推送、连接挂起占用资源
        transport.cancelActiveRequests()
    }

    /// 测试 / 调用方等待当前流式任务结束
    public func waitUntilIdle() async {
        guard let task = activeTask else { return }
        _ = await task.value
        // 让 MainActor 上的收尾代码执行完
        await Task.yield()
    }

    public func clearConversation() {
        stop()
        messages.removeAll()
        usage = nil
        selectedMessageID = nil
        meter.reset()
        logs.append(.info, "已清空对话")
    }

    // MARK: 内部实现

    private func buildWireMessages() -> [WireMessage] {
        var wire: [WireMessage] = []
        let system = systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !system.isEmpty {
            wire.append(WireMessage(role: .system, content: system))
        }
        for message in messages {
            guard message.role != .system else { continue }
            let content = message.content
            if content.isEmpty { continue }
            wire.append(WireMessage(role: message.role, content: content))
        }
        return wire
    }

    private nonisolated func runStream(baseURL: String,
                                       apiKey: String,
                                       versionPath: String,
                                       messages: [WireMessage],
                                       parameters: ChatParameters,
                                       assistant: MessageItem,
                                       flushInterval: TimeInterval) async {
        let buffer = StreamBuffer()
        var fullThinking = ""
        var fullAnswer = ""
        var usage: UsageInfo?
        var finishReason: String?
        var errorMessage: String?
        var lastFlush = Date()

        let flush: () async -> Void = {
            let taken = buffer.take()
            lastFlush = Date()
            if taken.thinking.isEmpty && taken.answer.isEmpty { return }
            let estimatedTokens = TokenEstimator.estimate(taken.thinking) + TokenEstimator.estimate(taken.answer)
            await MainActor.run { [weak self] in
                guard let self else { return }
                if !taken.thinking.isEmpty {
                    assistant.append(thinking: taken.thinking)
                }
                if !taken.answer.isEmpty {
                    assistant.append(content: taken.answer)
                }
                if estimatedTokens > 0 {
                    self.meter.add(estimatedTokens)
                }
                self.streamTick += 1
            }
        }

        let stream = client.streamChat(baseURL: baseURL,
                                       apiKey: apiKey,
                                       messages: messages,
                                       parameters: parameters,
                                       versionPath: versionPath)

        do {
            for try await event in stream {
                if Task.isCancelled { break }
                buffer.add(thinking: event.thinkingDelta, answer: event.answerDelta)
                fullThinking += event.thinkingDelta
                fullAnswer += event.answerDelta
                if let value = event.usage { usage = value }
                if let value = event.finishReason { finishReason = value }
                if let value = event.errorMessage { errorMessage = value }

                if buffer.pendingCount >= 64 || Date().timeIntervalSince(lastFlush) >= flushInterval {
                    await flush()
                }
            }
            await flush()
        } catch {
            if !(error is CancellationError) {
                errorMessage = error.localizedDescription
            }
        }

        let cancelled = Task.isCancelled
        let finalUsage = usage
        let finalFinish = finishReason
        let finalError = errorMessage
        let thinkingText = fullThinking
        let answerText = fullAnswer
        let sentMessages = messages

        await MainActor.run { [weak self] in
            guard let self else { return }
            self.finalize(
                assistant: assistant,
                cancelled: cancelled,
                usage: finalUsage,
                finishReason: finalFinish,
                errorMessage: finalError,
                thinkingText: thinkingText,
                answerText: answerText,
                sentMessages: sentMessages
            )
        }
    }

    private func finalize(assistant: MessageItem,
                          cancelled: Bool,
                          usage: UsageInfo?,
                          finishReason: String?,
                          errorMessage: String?,
                          thinkingText: String,
                          answerText: String,
                          sentMessages: [WireMessage]) {
        assistant.setStreaming(false)

        if let errorMessage {
            assistant.setError(errorMessage)
            lastError = errorMessage
        } else if cancelled {
            if answerText.isEmpty && thinkingText.isEmpty {
                assistant.setError("已停止")
            } else {
                assistant.appendSuffix("\n\n_（已停止生成）_")
            }
        }

        if let usage {
            self.usage = usage
            logs.append(.info, "用量统计：prompt=\(usage.promptTokens ?? 0) completion=\(usage.completionTokens ?? 0) total=\(usage.total)")
        } else if !cancelled, errorMessage == nil {
            let prompt = TokenEstimator.estimate(messages: sentMessages)
            let completion = TokenEstimator.estimate(thinkingText) + TokenEstimator.estimate(answerText)
            var estimate = UsageInfo(promptTokens: prompt,
                                     completionTokens: completion,
                                     totalTokens: prompt + completion,
                                     estimated: true)
            estimate.reasoningTokens = TokenEstimator.estimate(thinkingText)
            self.usage = estimate
            logs.append(.info, "服务端未返回用量，已按本地估算：prompt≈\(prompt) completion≈\(completion)")
        }

        isStreaming = false
        activeTask = nil
        logs.append(.info, "本轮结束（finish_reason=\(finishReason ?? "none")）")
    }

    // MARK: 持久化

    private func persist() {
        persistence.save(ConfigSnapshot(baseURL: baseURL,
                                  apiKey: apiKey,
                                  model: model,
                                  versionPath: versionPath,
                                  systemPrompt: systemPrompt,
                                  temperature: temperature,
                                  maxTokens: maxTokens,
                                  includeUsage: includeUsage,
                                  routeThinkTags: routeThinkTags))
    }

    private struct Persistence {
        let enabled: Bool
        let defaults: UserDefaults

        init(enabled: Bool) {
            self.enabled = enabled
            self.defaults = UserDefaults(suiteName: "com.llmdebugger.settings") ?? .standard
        }

        func load() -> ConfigSnapshot {
            guard enabled else { return defaultSnapshot() }
            let d = defaults
            return ConfigSnapshot(
                baseURL: d.string(forKey: "baseURL") ?? defaultSnapshot().baseURL,
                apiKey: d.string(forKey: "apiKey") ?? "",
                model: d.string(forKey: "model") ?? "",
                versionPath: d.string(forKey: "versionPath") ?? "v1",
                systemPrompt: d.string(forKey: "systemPrompt") ?? "",
                temperature: d.object(forKey: "temperature") as? Double ?? 0.7,
                maxTokens: d.object(forKey: "maxTokens") as? Int,
                includeUsage: d.object(forKey: "includeUsage") as? Bool ?? true,
                routeThinkTags: d.object(forKey: "routeThinkTags") as? Bool ?? true
            )
        }

        func save(_ snapshot: ConfigSnapshot) {
            guard enabled else { return }
            defaults.set(snapshot.baseURL, forKey: "baseURL")
            defaults.set(snapshot.apiKey, forKey: "apiKey")
            defaults.set(snapshot.model, forKey: "model")
            defaults.set(snapshot.versionPath, forKey: "versionPath")
            defaults.set(snapshot.systemPrompt, forKey: "systemPrompt")
            defaults.set(snapshot.temperature, forKey: "temperature")
            if let maxTokens = snapshot.maxTokens {
                defaults.set(maxTokens, forKey: "maxTokens")
            } else {
                defaults.removeObject(forKey: "maxTokens")
            }
            defaults.set(snapshot.includeUsage, forKey: "includeUsage")
            defaults.set(snapshot.routeThinkTags, forKey: "routeThinkTags")
        }

        private func defaultSnapshot() -> ConfigSnapshot {
            ConfigSnapshot(baseURL: "https://api.openai.com",
                     apiKey: "",
                     model: "",
                     versionPath: "v1",
                     systemPrompt: "",
                     temperature: 0.7,
                     maxTokens: nil,
                     includeUsage: true,
                     routeThinkTags: true)
        }
    }
}
