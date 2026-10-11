import SwiftUI
import LLMDebuggerCore

struct ConversationView: View {
    @ObservedObject var session: ChatSession

    @StateObject private var autoScroll = UIState(true)
    @StateObject private var hasReachedBottom = UIState(false)
    @StateObject private var viewport = UIState(CGRect.zero)
    @StateObject private var content = UIState(CGRect.zero)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(session.messages) { message in
                            MessageRow(message: message,
                                       isSelected: session.selectedMessageID == message.id) {
                                session.selectedMessageID = message.id
                            }
                            .id(message.id)
                            .onTapGesture {
                                guard message.role == .assistant else { return }
                                session.selectedMessageID =
                                    (session.selectedMessageID == message.id) ? nil : message.id
                            }
                        }
                    }
                    .padding(12)
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
                    // 几何变化只用于维护 autoScroll 开关（用户上滑暂停/回底恢复），
                    // 实际滚动由下方 streamTick / messages.count 数据驱动，确保可靠触发
                    updateAutoScrollFlagOnly(proxy)
                }
                .onChange(of: session.messages.count) { _ in
                    scrollToBottom(proxy)
                }
                .onChange(of: session.streamTick) { _ in
                    scrollToBottom(proxy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 数据驱动滚动：新增消息或流式增量到达时，若开启自动滚动则贴底
    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        guard autoScroll.value else { return }
        if let id = session.messages.last?.id {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    /// 几何变化仅用于维护 autoScroll 开关：
    /// 贴底（含内容未超出视口）→ 保持/恢复开启；曾贴底后远离 → 判定用户上滑，暂停。
    private func updateAutoScrollFlagOnly(_ proxy: ScrollViewProxy) {
        guard viewport.value != .zero, content.value != .zero else { return }
        let viewportHeight = viewport.value.height
        let scrollable = content.value.height > viewportHeight + 1
        if !scrollable {
            autoScroll.value = true
            hasReachedBottom.value = true
            return
        }
        let distance = viewport.value.maxY - content.value.maxY
        if distance <= 80 {
            autoScroll.value = true
            hasReachedBottom.value = true
        } else if hasReachedBottom.value {
            // 曾贴底、现在远离底部 → 判定为用户主动上滑查看历史，关闭自动滚动
            autoScroll.value = false
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 8) {
            Text("对话").font(.caption).foregroundColor(.secondary)
            if session.isStreaming {
                ProgressView().controlSize(.mini)
                Text("生成中…").font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            Toggle("自动滚动", isOn: $autoScroll.value)
                .toggleStyle(.checkbox)
                .font(.caption2)
            Button {
                session.clearConversation()
            } label: {
                Image(systemName: "trash")
            }
            .controlSize(.small)
            .help("清空对话")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

// MARK: - 单条消息

struct MessageRow: View {
    @ObservedObject var message: MessageItem
    var isSelected: Bool
    var onShowThinking: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text(message.role.displayName)
                    .font(.caption.bold())
                    .foregroundColor(titleColor)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(titleColor.opacity(0.14), in: Capsule())

                Text(timeText)
                    .font(.caption2)
                    .foregroundColor(.secondary)

                if message.isStreaming {
                    ProgressView().controlSize(.mini)
                }

                if let error = message.errorMessage {
                    Text(error)
                        .font(.caption2)
                        .foregroundColor(.red)
                        .lineLimit(1)
                        .help(error)
                }

                if message.role == .assistant && !message.thinking.isEmpty {
                    Button(action: onShowThinking) {
                        Image(systemName: "brain")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help("查看该条的思考过程")
                }
                Spacer()
            }

            if message.content.isEmpty {
                if message.isStreaming {
                    Text("等待响应…")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                } else if let error = message.errorMessage {
                    Text("请求失败：\(error)")
                        .font(.system(size: 13))
                        .foregroundColor(.red)
                }
            } else {
                Text(message.content)
                    .font(.system(size: 13.5))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.10) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.45) : Color.clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
    }

    private var titleColor: Color {
        switch message.role {
        case .user: return .blue
        case .assistant: return .green
        case .system: return .orange
        }
    }

    private var timeText: String {
        MessageRow.timeFormatter.string(from: message.createdAt)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}
