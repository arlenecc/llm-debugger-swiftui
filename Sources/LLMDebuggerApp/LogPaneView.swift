import SwiftUI
import LLMDebuggerCore

struct LogPaneView: View {
    @ObservedObject var store: LogStore
    @StateObject private var autoScroll = UIState(true)
    /// 每类日志一个勾选框：取消勾选即隐藏该类
    @StateObject private var visibleLevels = UIState(Set(LogLevel.allCases))
    @StateObject private var hasReachedBottom = UIState(false)
    @StateObject private var viewport = UIState(CGRect.zero)
    @StateObject private var content = UIState(CGRect.zero)

    private var visibleEntries: [LogEntry] {
        store.entries.filter { visibleLevels.value.contains($0.level) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("日志")
                    .font(.caption.bold())
                Spacer()
                Toggle("自动滚动", isOn: $autoScroll.value)
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                Button {
                    store.clear()
                } label: {
                    Image(systemName: "trash")
                }
                .controlSize(.small)
                .help("清空日志")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)

            Divider()

            // 每类日志一个选择框：取消勾选即可隐藏该类别
            HStack(spacing: 12) {
                Text("显示")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                ForEach(LogLevel.allCases) { level in
                    Toggle(level.displayName, isOn: Binding(
                        get: { visibleLevels.value.contains(level) },
                        set: { visibleLevels.value = $0 ? visibleLevels.value.union([level])
                                                       : visibleLevels.value.subtracting([level]) }
                    ))
                    .toggleStyle(.checkbox)
                    .font(.caption2)
                    .controlSize(.small)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleEntries) { entry in
                            LogRow(entry: entry) {
                                store.remove(id: entry.id)
                            }
                            .id(entry.id)
                        }
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
                    updateAutoScroll(proxy)
                }
                .onChange(of: store.entries.count) { _ in
                    guard autoScroll.value else { return }
                    if let id = visibleEntries.last?.id {
                        proxy.scrollTo(id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 自动滚动判定：基于内容底部(content.maxY)与视口的距离，用最后一条可见日志 id 滚动。
    /// `hasReachedBottom` 区分「初始停在顶部」与「用户上滑」，避免误关自动滚动。
    private func updateAutoScroll(_ proxy: ScrollViewProxy) {
        guard viewport.value != .zero, content.value != .zero else { return }
        let viewportHeight = viewport.value.height
        let scrollable = content.value.height > viewportHeight + 1
        if !scrollable {
            autoScroll.value = true
            hasReachedBottom.value = true
            if let id = visibleEntries.last?.id { proxy.scrollTo(id, anchor: .bottom) }
            return
        }
        let distance = viewport.value.maxY - content.value.maxY
        if distance <= 80 {
            autoScroll.value = true
            hasReachedBottom.value = true
            if distance < 0, let id = visibleEntries.last?.id {
                proxy.scrollTo(id, anchor: .bottom)
            }
        } else if hasReachedBottom.value {
            autoScroll.value = false
        }
    }
}

struct LogRow: View {
    let entry: LogEntry
    var onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(logTimestamp(entry.timestamp))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
            Text(entry.level.displayName)
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(entry.level.tint)
                .frame(width: 42, alignment: .leading)
            Text(entry.text)
                .font(.system(size: 11))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                onDelete()
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .foregroundColor(.secondary)
            .opacity(0.35)
            .help("删除此条")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .contextMenu {
            Button("删除此条") { onDelete() }
        }
    }
}
