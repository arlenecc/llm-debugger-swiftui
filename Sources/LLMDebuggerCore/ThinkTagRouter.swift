import Foundation

/// 把混在 `content` 里的 `<think>...</think>`（部分模型不提供 reasoning 字段）拆分成
/// 「思考过程」与「最终回复」两路，且能正确处理标签被 chunk 边界切断的情况。
///
/// 实现上完全在 UTF-8 字节空间操作，避免多字节字符被切断产生乱码。
public struct ThinkTagRouter {
    public static let openTags = ["<think>", "<thinking>"]
    public static let closeTags = ["</think>", "</thinking>"]
    public static let allTags = openTags + closeTags
    public static let maxTagLength = allTags.map(\.utf8.count).max() ?? 0

    private var inThink = false
    /// 因为可能是「半个标签」而暂存的尾部字节
    private var hold: [UInt8] = []

    public init() {}

    public var isInsideThink: Bool { inThink }

    public mutating func route(_ text: String) -> (thinking: String, answer: String) {
        guard !text.isEmpty else { return ("", "") }
        let incomingCount = text.utf8.count
        hold.append(contentsOf: text.utf8)

        var thinking: [UInt8] = []
        var answer: [UInt8] = []

        // 关键不变量：每次进入 `route` 时，`hold` 里不存在“完整标签”（已被本函数消费），
        // 且其尾部最多 (maxTagLength-1) 字节是某个标签的前缀（由 holdBackLength 保证）。
        // 因此新出现的完整标签只可能起始于「上次残留前缀」与「本次新增字节」交界的附近，
        // 只需从边界前 (maxTagLength-1) 字节开始扫描即可正确找到“第一个”标签；
        // 这样每轮只扫描 O(maxTagLength + 本段新增) 字节，整体由 O(n²) 降为 O(n)。
        var searchStart = max(0, hold.count - incomingCount - (Self.maxTagLength - 1))

        while true {
            guard hold.count > searchStart else { break }
            // 必须把扫描起点对齐到“字符边界”：否则从多字节字符中间切片后，
            // 解码出的替换字符会让 firstTag 算出的 byteStart 偏移错位。
            let safeStart = Self.charStart(hold, at: searchStart)
            guard hold.count > safeStart else { break }
            let slice = Array(hold[safeStart..<hold.count])
            guard let match = Self.firstTag(in: slice, tags: inThink ? Self.closeTags : Self.openTags) else { break }
            let byteStart = safeStart + match.byteStart

            let prefix = Array(hold[0..<byteStart])
            if inThink {
                thinking.append(contentsOf: prefix)
            } else {
                answer.append(contentsOf: prefix)
            }
            inThink.toggle()
            hold.removeSubrange(0..<(byteStart + match.byteLength))
            // 消费一个标签后，把扫描起点推进到该标签末尾附近，继续寻找下一个
            searchStart = max(0, byteStart + match.byteLength - (Self.maxTagLength - 1))
            if hold.isEmpty { break }
        }

        // 没有（更多）完整标签：只吐出不可能属于标签前缀的部分
        let keep = Self.holdBackLength(for: hold)
        let emitCount = hold.count - keep
        if emitCount > 0 {
            let emitted = Array(hold[0..<emitCount])
            if inThink {
                thinking.append(contentsOf: emitted)
            } else {
                answer.append(contentsOf: emitted)
            }
            hold.removeSubrange(0..<emitCount)
        }

        return (
            thinking: String(decoding: thinking, as: UTF8.self),
            answer: String(decoding: answer, as: UTF8.self)
        )
    }

    /// 流结束时调用，吐出残留内容
    public mutating func finish() -> (thinking: String, answer: String) {
        let remaining = String(decoding: hold, as: UTF8.self)
        hold.removeAll(keepingCapacity: true)
        if remaining.isEmpty { return ("", "") }
        if inThink { return (remaining, "") }
        return ("", remaining)
    }

    public mutating func reset() {
        inThink = false
        hold.removeAll(keepingCapacity: true)
    }

    // MARK: 内部实现

    private struct TagMatch {
        let byteStart: Int
        let byteLength: Int
    }

    /// 找到 `index` 所在（或之前）的“字符起始位置”：回退到最近的一个非 UTF-8 续字节，
    /// 保证从该位置切片解码不会出现错位。
    private static func charStart(_ bytes: [UInt8], at index: Int) -> Int {
        var i = index
        if i > bytes.count { i = bytes.count }
        while i > 0 {
            let b = bytes[i - 1]
            if (b & 0xC0) != 0x80 {
                // 该字节是首字节（或 ASCII），字符从此处开始
                return i - 1
            }
            i -= 1
        }
        return 0
    }

    /// 在字节缓冲区里找出最早出现的标签（忽略大小写）
    private static func firstTag(in bytes: [UInt8], tags: [String]) -> TagMatch? {
        guard !bytes.isEmpty else { return nil }
        let text = String(decoding: bytes, as: UTF8.self)
        var bestStart: Int?
        var bestLength = 0
        for tag in tags {
            guard let range = text.range(of: tag, options: .caseInsensitive) else { continue }
            let byteStart = text.utf8.distance(from: text.startIndex, to: range.lowerBound)
            if bestStart == nil || byteStart < bestStart! {
                bestStart = byteStart
                bestLength = tag.utf8.count
            }
        }
        guard let bestStart else { return nil }
        return TagMatch(byteStart: bestStart, byteLength: bestLength)
    }

    /// 计算需要保留在缓冲区里的尾部字节数（可能是半个标签）
    private static func holdBackLength(for bytes: [UInt8]) -> Int {
        let upper = min(maxTagLength - 1, bytes.count)
        var length = upper
        while length > 0 {
            let suffix = String(decoding: bytes.suffix(length), as: UTF8.self).lowercased()
            if allTags.contains(where: { $0.lowercased().hasPrefix(suffix) }) {
                return length
            }
            length -= 1
        }
        return 0
    }
}
