import SwiftUI
import AppKit
import LLMDebuggerCore

struct ConfigBarView: View {
    @ObservedObject var session: ChatSession

    @StateObject private var showAPIKey = UIState(false)
    @StateObject private var showAdvanced = UIState(false)
    @StateObject private var showModelPicker = UIState(false)
    @StateObject private var modelFilter = UIState("")

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                baseURLField
                    .frame(minWidth: 260, maxWidth: .infinity)

                apiKeyField
                    .frame(width: 250)

                modelField
                    .frame(width: 250)

                VStack(alignment: .leading, spacing: 4) {
                    Text("状态").font(.caption2).foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        Button {
                            showAdvanced.value.toggle()
                        } label: {
                            Label("高级", systemImage: "slider.horizontal.3")
                        }
                        .popover(isPresented: $showAdvanced.value, arrowEdge: .bottom) {
                            advancedPanel
                        }
                        .controlSize(.small)

                        statusText
                        Spacer(minLength: 0)
                    }
                    .frame(height: 22)
                }
                .frame(width: 150)
            }

            resolvedHint
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: 子视图

    private var baseURLField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("服务地址 Base URL").font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 6) {
                TextField("https://api.openai.com", text: $session.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                Button {
                    Task { await session.refreshModels() }
                } label: {
                    if session.isFetchingModels {
                        ProgressView().controlSize(.small).frame(width: 14, height: 14)
                    } else {
                        Text("获取模型")
                    }
                }
                .disabled(session.isFetchingModels || session.baseURL.trimmed.isEmpty)
                .controlSize(.small)
                .help("GET {baseURL}/v1/models")
            }
        }
    }

    private var apiKeyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API Key").font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 6) {
                Group {
                    if showAPIKey.value {
                        TextField("sk-…", text: $session.apiKey)
                    } else {
                        SecureField("sk-…", text: $session.apiKey)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

                Button {
                    showAPIKey.value.toggle()
                } label: {
                    Image(systemName: showAPIKey.value ? "eye.slash" : "eye")
                }
                .controlSize(.small)
                .help(showAPIKey.value ? "隐藏" : "显示")
            }
        }
    }

    private var modelField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("模型名称").font(.caption2).foregroundColor(.secondary)
            HStack(spacing: 6) {
                TextField("gpt-4o", text: $session.model)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))

                Button {
                    showModelPicker.value.toggle()
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .symbolRenderingMode(.hierarchical)
                }
                .controlSize(.small)
                .disabled(session.models.isEmpty)
                .help("从已获取的 \(session.models.count) 个模型中选择")
                .popover(isPresented: $showModelPicker.value, arrowEdge: .bottom) {
                    modelPicker
                }
            }
        }
    }

    private var modelPicker: some View {
        VStack(spacing: 6) {
            TextField("过滤模型…", text: $modelFilter.value)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(filteredModels) { model in
                        Button {
                            session.model = model.id
                            showModelPicker.value = false
                            modelFilter.value = ""
                        } label: {
                            HStack {
                                Image(systemName: session.model == model.id ? "checkmark" : "")
                                    .frame(width: 12)
                                Text(model.id).font(.system(size: 12))
                                Spacer()
                                if let owned = model.ownedBy, !owned.isEmpty {
                                    Text(owned).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                            .padding(.horizontal, 6)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 240)

            Text("共 \(session.models.count) 个模型")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(10)
        .frame(width: 320)
    }

    private var filteredModels: [ModelInfo] {
        let filter = modelFilter.value.trimmed.lowercased()
        guard !filter.isEmpty else { return session.models }
        return session.models.filter { $0.id.lowercased().contains(filter) }
    }

    private var statusText: some View {
        Group {
            if let error = session.modelsError {
                Text(error).font(.caption2).foregroundColor(.red).lineLimit(1).help(error)
            } else if !session.models.isEmpty {
                Text("\(session.models.count) 个模型").font(.caption2).foregroundColor(.secondary)
            } else if let error = session.lastError {
                Text(error).font(.caption2).foregroundColor(.red).lineLimit(1).help(error)
            } else {
                Text("就绪").font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private var resolvedHint: some View {
        let text: String
        do {
            let resolved = try EndpointResolver.resolve(session.baseURL, versionPath: session.versionPath)
            text = "POST  \(resolved.chatCompletionsURL.absoluteString)"
        } catch {
            text = error.localizedDescription
        }
        return Text(text)
            .font(.system(size: 10.5, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .help(text)
    }

    private var advancedPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("高级参数").font(.headline)

            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("版本路径").font(.caption2).foregroundColor(.secondary)
                    TextField("v1", text: $session.versionPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 70)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("温度 \(session.temperature, specifier: "%.2f")")
                        .font(.caption2).foregroundColor(.secondary)
                    Slider(value: $session.temperature, in: 0...2, step: 0.05)
                        .frame(width: 150)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("最大输出 Token").font(.caption2).foregroundColor(.secondary)
                    HStack(spacing: 4) {
                        TextField("不限制", value: $session.maxTokens, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                        if session.maxTokens != nil {
                            Button {
                                session.maxTokens = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundColor(.secondary)
                        }
                    }
                }
            }

            Toggle("请求用量统计 stream_options.include_usage", isOn: $session.includeUsage)
                .font(.caption)
                .help("部分兼容服务不支持该字段，报错时可关闭")

            Toggle("识别 content 中的 <think> 标签", isOn: $session.routeThinkTags)
                .font(.caption)
                .help("模型未返回 reasoning_content、而是把推理写在正文里时开启")

            VStack(alignment: .leading, spacing: 4) {
                Text("系统提示词").font(.caption2).foregroundColor(.secondary)
                TextEditor(text: $session.systemPrompt)
                    .font(.system(size: 12))
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.separator))
            }
        }
        .padding(12)
        .frame(width: 460)
    }
}
