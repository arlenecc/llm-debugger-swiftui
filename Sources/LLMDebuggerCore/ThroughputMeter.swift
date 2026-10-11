import Foundation

// MARK: - 推理速率

public struct ThroughputSnapshot: Equatable, Sendable {
    public let tokens: Int
    public let tokensPerSecond: Double
    public let elapsed: TimeInterval

    public init(tokens: Int, tokensPerSecond: Double, elapsed: TimeInterval) {
        self.tokens = tokens
        self.tokensPerSecond = tokensPerSecond
        self.elapsed = elapsed
    }
}

/// 统计输出 token 与实时速率。
/// 速率优先使用滑动窗口（默认 3 秒），窗口太短时回退到整段平均值，避免除零与抖动。
public final class ThroughputMeter {
    private let clock: () -> TimeInterval
    private let window: TimeInterval

    private var startTime: TimeInterval?
    private var samples: [(time: TimeInterval, tokens: Int)] = []
    private var total = 0

    public init(window: TimeInterval = 3.0,
                clock: @escaping () -> TimeInterval = { Date().timeIntervalSinceReferenceDate }) {
        self.window = window
        self.clock = clock
    }

    public func reset() {
        startTime = nil
        samples.removeAll(keepingCapacity: true)
        total = 0
    }

    public func start() {
        if startTime == nil {
            startTime = clock()
            samples.removeAll(keepingCapacity: true)
            total = 0
        }
    }

    public func add(_ tokens: Int) {
        guard tokens > 0 else { return }
        if startTime == nil { start() }
        total += tokens
        samples.append((time: clock(), tokens: tokens))
    }

    public var totalTokens: Int { total }

    public func snapshot() -> ThroughputSnapshot {
        guard let start = startTime else {
            return ThroughputSnapshot(tokens: total, tokensPerSecond: 0, elapsed: 0)
        }
        let now = clock()
        let elapsed = max(0, now - start)

        let cutoff = now - window
        if let firstIndex = samples.firstIndex(where: { $0.time >= cutoff }) {
            samples.removeSubrange(0..<firstIndex)
        } else if !samples.isEmpty {
            // 窗口内没有样本：只保留最后一个，避免速率突降到 0
            if samples.count > 1 { samples.removeSubrange(0..<(samples.count - 1)) }
        }

        let windowTokens = samples.reduce(0) { $0 + $1.tokens }
        let windowStart = samples.first?.time ?? start
        let windowSpan = max(0, now - windowStart)

        let speed: Double
        if windowSpan >= 0.2, windowTokens > 0 {
            speed = Double(windowTokens) / windowSpan
        } else if elapsed >= 0.05, total > 0 {
            speed = Double(total) / elapsed
        } else {
            speed = 0
        }

        return ThroughputSnapshot(tokens: total, tokensPerSecond: speed, elapsed: elapsed)
    }
}
