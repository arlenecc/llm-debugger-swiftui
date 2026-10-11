import SwiftUI
import AppKit
import LLMDebuggerCore

@main
struct LLMDebuggerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 1060, minHeight: 680)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }
}

// MARK: - 视图局部状态容器
//
// 说明：本机工具链（仅 Command Line Tools）缺少 SwiftUIMacros 插件，`@State` 无法展开。
// 这里用 ObservableObject + @StateObject 承载视图局部状态，语义等价且可编译。
public final class UIState<Value>: ObservableObject {
    @Published public var value: Value
    public init(_ value: Value) { self.value = value }
}

// MARK: - 小工具

extension View {
    /// 悬停时切换鼠标指针
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension Color {
    static var separator: Color { Color(nsColor: .separatorColor) }
    static var panelBackground: Color { Color(nsColor: .controlBackgroundColor) }
}

extension LogLevel {
    var tint: Color {
        switch self {
        case .info: return .secondary
        case .request: return .blue
        case .response: return .green
        case .stream: return .purple
        case .error: return .red
        }
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

func formattedToken(_ value: Int) -> String {
    staticTokenFormatter().string(from: NSNumber(value: value)) ?? "\(value)"
}

func logTimestamp(_ date: Date) -> String {
    staticTimestampFormatter().string(from: date)
}

/// 缓存格式化器：避免每次调用都重建（日志面板每帧为每条日志创建，开销可观）
private func staticTokenFormatter() -> NumberFormatter {
    struct Holder { static let formatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }() }
    return Holder.formatter
}

private func staticTimestampFormatter() -> DateFormatter {
    struct Holder { static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }() }
    return Holder.formatter
}

// MARK: - 滚动位置偏好键（用于自动贴底判断）

/// 滚动视图可视区域（视口）在全局坐标系中的 frame
struct ScrollViewportKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

/// 滚动内容整体的 frame（用于判断是否可滚动及计算贴底距离）
struct ScrollContentKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}
