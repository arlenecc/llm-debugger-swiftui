# LLM Debugger

一款面向 macOS 的原生 SwiftUI 调试工具，用于实时观测 OpenAI 兼容接口的流式（SSE）输出行为：对话、思考过程、Token 速率与原始日志，一目了然。

## 功能特性

### 对话
- 基于 OpenAI Chat Completions 协议的流式对话（`stream: true`）
- 兼容各类 OpenAI 兼容端点（自定义 `baseURL` / `versionPath`，如 `/v1`）
- 自动处理服务端忽略 `stream` 参数、直接返回完整 JSON 的情况
- 点选任意一条助手消息即可单独查看其思考过程

### 思考过程
- 实时展示 `<think>` 标签内容与 `reasoning` 增量，可按消息切换
- 支持思维链路由开关（`routeThinkTags`）
- 实时显示推理输出速率（tok/s，滑动窗口）与 token 消耗

### 日志
- 按类别（信息 / 请求 / 响应 / 流数据 / 错误）独立勾选显示或隐藏
- 支持单条删除与一键清空
- 环形缓冲 + 合批刷新（100 ms），高频流式输出下不卡 UI
- 三处（对话 / 思考过程 / 日志）均支持自动贴底跟随：上滑查看历史自动暂停，回到底部自动恢复

### 其他
- API Key 通过 macOS 钥匙串（Keychain）安全存储，配置本地持久化
- Token 用量统计：优先使用服务端返回的 `usage`，缺失时按本地规则估算（带 `≈` 标记）
- 停止生成时立即作废底层连接，避免连接挂起
- 精选常见错误的服务端信息透出（HTTP 状态、`error.message`）

## 系统要求

- macOS 13.0+
- Swift 5.9+（Command Line Tools 或 Xcode 15+）

## 构建与运行

### 使用 Xcode

```bash
open Package.swift   # Xcode 会自动识别 Swift Package，直接 ⌘R 运行
```

### 使用命令行

```bash
swift build            # debug 构建
swift run LLMDebuggerApp

swift build -c release # release 构建
```

### 打包为 .app / DMG

```bash
swift build -c release
mkdir -p "dist/LLM Debugger.app/Contents/MacOS" "dist/LLM Debugger.app/Contents/Resources"
cp .build/release/LLMDebuggerApp "dist/LLM Debugger.app/Contents/MacOS/"
cp AppIcon.icns "dist/LLM Debugger.app/Contents/Resources/AppIcon.icns"
# Info.plist 参考 dist/LLM Debugger.app/Contents/Info.plist
codesign --force --deep --sign - "dist/LLM Debugger.app"
hdiutil create -volname "LLM Debugger" -srcfolder "dist/LLM Debugger.app" -ov -format UDZO "dist/LLM Debugger.dmg"
```

## 测试

测试为独立可执行运行器（非 XCTest 目标）：

```bash
swift run LLMDebuggerTests
```

覆盖范围：SSE 解析、思考标签路由（含跨 chunk 标签切分、多标签、非法前缀）、Chunk 解码、HTTP 传输行为（Mock / 本地测试服务器）等。

## 项目结构

```
Sources/
├── LLMDebuggerCore/          # 纯逻辑层，无 UI 依赖，可独立复用
│   ├── ChatSession.swift     # 会话引擎：消息状态、流式节流、用量统计
│   ├── OpenAIClient.swift    # OpenAI 兼容客户端（SSE 流式 / 非流式 / 模型列表）
│   ├── HTTPTransport.swift   # 传输抽象 + URLSession 实现（可取消、可替换）
│   ├── SSEParser.swift       # SSE 事件解析（字节流 → 事件）
│   ├── ChunkDecoder.swift    # 增量解码（含 <think> 标签路由开关）
│   ├── ThinkTagRouter.swift  # 流式 <think> 标签路由（O(n)，容忍跨 chunk 切分）
│   ├── LogStore.swift        # 环形缓冲 + 合批刷新的日志仓库
│   ├── ThroughputMeter.swift # 滑动窗口速率统计
│   ├── TokenEstimator.swift  # 本地 token 估算
│   ├── EndpointResolver.swift# baseURL/versionPath 解析
│   ├── Secrets.swift         # Keychain 存取
│   └── Models.swift          # 协议模型
└── LLMDebuggerApp/           # SwiftUI 展示层
    ├── LLMDebuggerApp.swift  # 入口与通用 UI 状态工具
    ├── ContentView.swift     # 主布局
    ├── ConversationView.swift# 对话区
    ├── ThinkingView.swift    # 思考过程区
    ├── LogPaneView.swift     # 日志区
    ├── ConfigBarView.swift   # 顶部配置栏
    └── MessageInputView.swift# 输入框

Tests/LLMDebuggerTests/       # 独立测试运行器（含 MockTransport、本地测试服务器）
```

## 使用说明

1. 首次启动后在顶部配置栏填写 **Base URL**（如 `https://api.openai.com`）与 **API Key**；
2. 点击刷新获取模型列表，或直接输入模型名；
3. 在输入框发送消息，对话区、思考过程区、日志区将实时同步展示；
4. 可在配置栏调节 temperature / max_tokens / 系统提示词等参数。

> 若从 DMG 安装首次打开被 Gatekeeper 拦截，执行 `xattr -cr "/Applications/LLM Debugger.app"` 后即可正常启动（构建为 ad-hoc 签名，未公证）。

## License

MIT
