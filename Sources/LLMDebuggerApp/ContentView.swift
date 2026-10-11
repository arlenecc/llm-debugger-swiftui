import SwiftUI
import LLMDebuggerCore

struct ContentView: View {
    @StateObject private var session = ChatSession()
    @StateObject private var leftRatio = UIState<CGFloat>(2.0 / 3.0)

    var body: some View {
        GeometryReader { geo in
            // 顶部 1/6 为配置区（设置最小高度，窗口很小时仍然可用）
            let configHeight = max(148, geo.size.height / 6)

            VStack(spacing: 0) {
                ConfigBarView(session: session)
                    .frame(height: configHeight)

                Divider()

                HSplitView(ratio: $leftRatio.value) {
                    LeftPaneView(session: session)
                } right: {
                    LogPaneView(store: session.logs)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.panelBackground)
    }
}

// MARK: - 左侧（对话 / 输入 / 思考）

struct LeftPaneView: View {
    @ObservedObject var session: ChatSession

    var body: some View {
        GeometryReader { geo in
            let inputHeight: CGFloat = 138
            let thinkingHeight = max(150, (geo.size.height - inputHeight) * 0.34)

            VStack(spacing: 0) {
                ConversationView(session: session)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                Divider()

                MessageInputView(session: session)
                    .frame(height: inputHeight)

                Divider()

                ThinkingView(session: session)
                    .frame(height: thinkingHeight)
            }
        }
    }
}

// MARK: - 可拖拽的横向分栏（默认左 2/3）

struct HSplitView<Left: View, Right: View>: View {
    @Binding var ratio: CGFloat

    private let minRatio: CGFloat = 0.32
    private let maxRatio: CGFloat = 0.82

    @StateObject private var startRatio = UIState<CGFloat?>(nil)
    @ViewBuilder var left: () -> Left
    @ViewBuilder var right: () -> Right

    var body: some View {
        GeometryReader { geo in
            let total = max(geo.size.width, 1)
            let clamped = min(max(ratio, minRatio), maxRatio)

            HStack(spacing: 0) {
                left()
                    .frame(width: max(280, total * clamped))
                    .frame(maxHeight: .infinity)

                handle(totalWidth: total)

                right()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func handle(totalWidth: CGFloat) -> some View {
        ZStack {
            Rectangle()
                .fill(Color.separator)
                .frame(width: 1)
            Rectangle()
                .fill(Color.clear)
                .frame(width: 9)
                .contentShape(Rectangle())
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if startRatio.value == nil { startRatio.value = ratio }
                    let base = startRatio.value ?? ratio
                    let next = base + value.translation.width / totalWidth
                    ratio = min(max(next, minRatio), maxRatio)
                }
                .onEnded { _ in startRatio.value = nil }
        )
        .cursor(.resizeLeftRight)
    }
}
