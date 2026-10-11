import SwiftUI
import AppKit
import LLMDebuggerCore

struct ThinkingView: View {
    @ObservedObject var session: ChatSession
    @StateObject private var autoScrollFollow = UIState(true)

    /// 当前要展示思考过程的消息：优先选中消息，否则跟随最新一条助手消息
    private var target: MessageItem? {
        if let id = session.selectedMessageID,
           let message = session.messages.first(where: { $0.id == id }),
           message.role == .assistant {
            return message
        }
        return session.messages.last { $0.role == .assistant }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if let message = target {
                // 直接观察具体的 MessageItem，思考增量会实时驱动重渲染
                ThinkingContentView(message: message, session: session, autoScroll: $autoScrollFollow.value)
            } else {
                placeholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var placeholder: some View {
        Text("暂无思考过程（发送消息后，模型若返回 reasoning / <think> 内容将在此实时显示）")
            .font(.system(size: 12.5))
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(10)
    }

    // MARK: 头部：标签 + 实时速率 + token 消耗

    private var header: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "brain")
                    .foregroundColor(.purple)
                Text("思考过程")
                    .font(.caption.bold())
            }

            TimelineView(.animation(minimumInterval: 0.25, paused: !session.isStreaming)) { _ in
                statsRow
            }

            Spacer()

            if session.selectedMessageID != nil {
                Button {
                    session.selectedMessageID = nil
                } label: {
                    Text("跟随最新")
                }
                .controlSize(.mini)
                .help("取消选中，跟随最新一轮")
            }

            Toggle("自动滚动", isOn: $autoScrollFollow.value)
                .toggleStyle(.checkbox)
                .font(.caption2)

            Button {
                copyThinking()
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .controlSize(.small)
            .help("复制思考过程")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var statsRow: some View {
        let snapshot = session.meter.snapshot()
        let usage = session.usage

        return HStack(spacing: 6) {
            StatChip(text: String(format: "%.1f tok/s", snapshot.tokensPerSecond),
                     tint: .purple)

            if let usage {
                if let reasoning = usage.reasoningTokens {
                    StatChip(text: "推理 \(formattedToken(reasoning)) tok", tint: .secondary)
                }
                if let completion = usage.completionTokens {
                    StatChip(text: "输出 \(formattedToken(completion)) tok", tint: .secondary)
                }
                StatChip(text: "合计 \(formattedToken(usage.total))\(usage.estimated ? "≈" : "") tok",
                         tint: .blue)
            } else if snapshot.tokens > 0 {
                StatChip(text: "已输出 \(formattedToken(snapshot.tokens)) tok≈", tint: .secondary)
            }
        }
        .help("推理输出速率（滑动窗口）与 token 消耗；≈ 表示按本地规则估算")
    }

    private func copyThinking() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.displayedThinking, forType: .string)
    }
}

/// 真正渲染思考文本的子视图：观察 `message`，流式增量到来时即时重渲染
struct ThinkingContentView: View {
    @ObservedObject var message: MessageItem
    @ObservedObject var session: ChatSession
    @Binding var autoScroll: Bool

    @StateObject private var hasReachedBottom = UIState(false)
    @StateObject private var viewport = UIState(CGRect.zero)
    @StateObject private var content = UIState(CGRect.zero)
    private let bottomID = "thinking-bottom"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(displayText)
                        .font(.system(size: 12.5))
                        .foregroundColor(.primary.opacity(0.85))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    Color.clear
                        .frame(height: 1)
                        .id(bottomID)
                }
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ScrollContentKey.self,
                                               value: geo.frame(in: .global))
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                GeometryReader { geo in
                    Color.clear.preference(key: ScrollViewportKey.self,
                                           value: geo.frame(in: .global))
                }
            )
            .onPreferenceChange(ScrollViewportKey.self) { viewport.value = $0 }
            .onPreferenceChange(ScrollContentKey.self) { content.value = $0 }
            .onChange(of: content.value) { _ in
                // 几何变化仅用于维护 autoScroll 开关（上滑暂停/回底恢复）
                updateAutoScrollFlagOnly()
            }
            .onChange(of: message.thinking) { _ in
                // 本视图直接观察 message，思考增量必触发重渲染，用数据驱动滚动最可靠
                guard autoScroll else { return }
                proxy.scrollTo(bottomID, anchor: .bottom)
            }
        }
    }

    private func updateAutoScrollFlagOnly() {
        guard viewport.value != .zero, content.value != .zero else { return }
        let viewportHeight = viewport.value.height
        let scrollable = content.value.height > viewportHeight + 1
        if !scrollable {
            autoScroll = true
            hasReachedBottom.value = true
            return
        }
        let distance = viewport.value.maxY - content.value.maxY
        if distance <= 80 {
            autoScroll = true
            hasReachedBottom.value = true
        } else if hasReachedBottom.value {
            // 曾贴底、现在远离底部 → 用户主动上滑查看，暂停自动滚动
            autoScroll = false
        }
    }

    private var displayText: String {
        let text = message.thinking
        if text.isEmpty {
            if session.isStreaming { return "等待模型输出思考过程…" }
            return "暂无思考过程（该模型可能未返回 reasoning / <think> 内容）"
        }
        return text
    }
}

struct StatChip: View {
    let text: String
    var tint: Color = .secondary

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.12), in: Capsule())
    }
}
