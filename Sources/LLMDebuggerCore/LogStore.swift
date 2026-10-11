import Foundation
import Combine

// MARK: - 日志

public enum LogLevel: String, CaseIterable, Sendable, Identifiable, Codable {
    case info
    case request
    case response
    case stream
    case error

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .info: return "信息"
        case .request: return "请求"
        case .response: return "响应"
        case .stream: return "流数据"
        case .error: return "错误"
        }
    }
}

public struct LogEntry: Identifiable, Equatable, Sendable {
    public let id: Int
    public let timestamp: Date
    public let level: LogLevel
    public let text: String

    public init(id: Int, timestamp: Date, level: LogLevel, text: String) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.text = text
    }
}

public protocol WireLogger: AnyObject, Sendable {
    func log(_ level: LogLevel, _ message: String)
}

/// 环形缓冲 + 合批刷新的日志仓库：
/// - 后台线程可以高频调用 `log`，不会产生 SwiftUI 抖动；
/// - 主线程每 `flushInterval` 秒合并写入一次 `@Published entries`。
public final class LogStore: ObservableObject, WireLogger, @unchecked Sendable {
    @Published public private(set) var entries: [LogEntry] = []

    public let capacity: Int
    public let flushInterval: TimeInterval

    private let lock = NSLock()
    private var pending: [LogEntry] = []
    private var nextID = 0
    private var flushScheduled = false

    public init(capacity: Int = 2000, flushInterval: TimeInterval = 0.1) {
        self.capacity = max(1, capacity)
        self.flushInterval = max(0, flushInterval)
    }

    public func log(_ level: LogLevel, _ message: String) {
        append(level, message)
    }

    public func append(_ level: LogLevel, _ message: String) {
        lock.lock()
        let entry = LogEntry(id: nextID, timestamp: Date(), level: level, text: message)
        nextID += 1
        pending.append(entry)
        let shouldSchedule = !flushScheduled
        if shouldSchedule { flushScheduled = true }
        lock.unlock()

        guard shouldSchedule else { return }
        let delay = flushInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.flushScheduled = false
            self.lock.unlock()
            self.flush()
        }
    }

    /// 主线程：把暂存的日志合并写入 `entries`（测试里可显式调用以获得确定性结果）
    public func flush() {
        if !Thread.isMainThread {
            DispatchQueue.main.sync { flush() }
            return
        }
        lock.lock()
        let batch = pending
        if !batch.isEmpty { pending.removeAll(keepingCapacity: true) }
        lock.unlock()

        guard !batch.isEmpty else { return }

        var next = entries
        next.append(contentsOf: batch)
        if next.count > capacity {
            next.removeFirst(next.count - capacity)
        }
        entries = next
    }

    public func clear() {
        lock.lock()
        pending.removeAll(keepingCapacity: true)
        lock.unlock()
        if Thread.isMainThread {
            entries = []
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.entries = []
            }
        }
    }

    /// 删除单条日志（主线程重赋值以触发 @Published 通知）
    public func remove(id: Int) {
        let apply = { [weak self] in
            guard let self else { return }
            self.entries = self.entries.filter { $0.id != id }
        }
        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async(execute: apply)
        }
    }

    /// 测试辅助：把暂存的日志立刻合并进 `entries`（任意线程调用均安全）
    public func flushAndWait() {
        if Thread.isMainThread {
            flush()
        } else {
            DispatchQueue.main.sync { self.flush() }
        }
    }
}
