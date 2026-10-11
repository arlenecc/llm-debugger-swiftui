import Foundation
import LLMDebuggerCore

/// 用例组 E：Token 估算
@MainActor
func tokenEstimatorTests() -> [MiniTest] {
    [
        MiniTest("E1 空文本为 0") {
            try XCTAssertEqual(TokenEstimator.estimate(""), 0)
        },

        MiniTest("E2 纯英文按 4 字符 1 token") {
            try XCTAssertEqual(TokenEstimator.estimate("hello"), 2)
            try XCTAssertEqual(TokenEstimator.estimate("abcd"), 1)
            try XCTAssertEqual(TokenEstimator.estimate("abcdefgh"), 2)
        },

        MiniTest("E3 中文按 1 字符 1 token") {
            try XCTAssertEqual(TokenEstimator.estimate("你好世界"), 4)
        },

        MiniTest("E4 中英混排") {
            try XCTAssertEqual(TokenEstimator.estimate("你好hello"), 4)
        },

        MiniTest("E5 长文本单调不减") {
            let a = TokenEstimator.estimate("abc")
            let b = TokenEstimator.estimate("abc def ghij klmn")
            try XCTAssertGreaterThan(b, a)
        },

        MiniTest("E6 消息列表估算包含开销") {
            let messages = [WireMessage(role: .user, content: "你好")]
            try XCTAssertEqual(TokenEstimator.estimate(messages: messages), 8)
        },

        MiniTest("E7 emoji 不会产生负数或崩溃") {
            try XCTAssertGreaterThan(TokenEstimator.estimate("🎉👍"), 0)
        }
    ]
}

/// 用例组 F：实时速率统计
@MainActor
func throughputMeterTests() -> [MiniTest] {
    [
        MiniTest("F1 未开始时速率为 0") {
            let meter = ThroughputMeter(clock: { 0 })
            try XCTAssertEqual(meter.snapshot().tokensPerSecond, 0)
        },

        MiniTest("F2 累计 token 数正确") {
            let meter = ThroughputMeter(clock: { 0 })
            meter.add(10)
            meter.add(5)
            try XCTAssertEqual(meter.snapshot().tokens, 15)
        },

        MiniTest("F3 用滑动窗口计算速率") {
            var now: TimeInterval = 0
            let meter = ThroughputMeter(window: 2, clock: { now })
            meter.add(10)
            now = 1
            meter.add(10)
            let snapshot = meter.snapshot()
            try XCTAssertEqual(snapshot.tokensPerSecond, 20, accuracy: 0.001)
        },

        MiniTest("F4 窗口外的样本会被丢弃") {
            var now: TimeInterval = 0
            let meter = ThroughputMeter(window: 1, clock: { now })
            meter.add(100)          // t=0，早已滑出窗口
            now = 10
            meter.add(10)           // t=10
            now = 11
            meter.add(10)           // t=11
            let snapshot = meter.snapshot()
            try XCTAssertEqual(snapshot.tokens, 120, "累计 token 不受窗口影响")
            try XCTAssertEqual(snapshot.tokensPerSecond, 20, accuracy: 0.001, "速率只统计最近 1 秒")
        },

        MiniTest("F5 极短间隔不产生无穷大") {
            var now: TimeInterval = 0
            let meter = ThroughputMeter(clock: { now })
            meter.add(5)
            now = 0.001
            let snapshot = meter.snapshot()
            try XCTAssertFalse(snapshot.tokensPerSecond.isNaN)
            try XCTAssertFalse(snapshot.tokensPerSecond.isInfinite)
        },

        MiniTest("F6 reset 清空状态") {
            let meter = ThroughputMeter(clock: { 0 })
            meter.add(10)
            meter.reset()
            try XCTAssertEqual(meter.snapshot().tokens, 0)
            try XCTAssertEqual(meter.snapshot().tokensPerSecond, 0)
        },

        MiniTest("F7 elapsed 被统计") {
            var now: TimeInterval = 100
            let meter = ThroughputMeter(clock: { now })
            meter.add(1)
            now = 103
            try XCTAssertEqual(meter.snapshot().elapsed, 3, accuracy: 0.001)
        },

        MiniTest("F8 添加 0 或负数被忽略") {
            let meter = ThroughputMeter(clock: { 0 })
            meter.add(0)
            meter.add(-5)
            try XCTAssertEqual(meter.snapshot().tokens, 0)
        }
    ]
}
