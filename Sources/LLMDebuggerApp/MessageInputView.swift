import SwiftUI
import AppKit
import LLMDebuggerCore

struct MessageInputView: View {
    @ObservedObject var session: ChatSession

    @StateObject private var draft = UIState("")

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("发送消息").font(.caption).foregroundColor(.secondary)
                Spacer()
                Text("⌘ + ↩ 发送")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }

            ZStack(alignment: .topLeading) {
                TextEditor(text: $draft.value)
                    .font(.system(size: 13))
                    .padding(4)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.separator, lineWidth: 1)
                    )

                if draft.value.isEmpty {
                    Text("输入内容后发送；支持多行，⌘ + ↩ 直接发送")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }

            HStack(spacing: 8) {
                if let usage = session.usage {
                    Text(usageSummary(usage))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()

                if session.isStreaming {
                    Button {
                        session.stop()
                    } label: {
                        Label("停止", systemImage: "stop.fill")
                    }
                    .controlSize(.small)
                    .keyboardShortcut(".", modifiers: .command)
                }

                Button {
                    send()
                } label: {
                    Label("发送", systemImage: "paperplane.fill")
                }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!session.canSend || draft.value.trimmed.isEmpty)
                .help(draft.value.trimmed.isEmpty
                      ? "输入消息后发送（⌘ + ↩）"
                      : (!session.canSend ? "请先填写服务地址与模型名称" : "发送（⌘ + ↩）"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func send() {
        let text = draft.value
        draft.value = ""
        session.send(text)
    }

    private func usageSummary(_ usage: UsageInfo) -> String {
        var parts: [String] = []
        if let prompt = usage.promptTokens { parts.append("输入 \(formattedToken(prompt))") }
        if let completion = usage.completionTokens { parts.append("输出 \(formattedToken(completion))") }
        parts.append("合计 \(formattedToken(usage.total))\(usage.estimated ? "≈" : "")")
        return "上一轮用量：" + parts.joined(separator: " · ") + " tok"
    }
}
