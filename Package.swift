// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LLMDebugger",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "LLMDebuggerCore", targets: ["LLMDebuggerCore"]),
        .executable(name: "LLMDebuggerApp", targets: ["LLMDebuggerApp"])
    ],
    targets: [
        .target(
            name: "LLMDebuggerCore",
            path: "Sources/LLMDebuggerCore"
        ),
        .executableTarget(
            name: "LLMDebuggerApp",
            dependencies: ["LLMDebuggerCore"],
            path: "Sources/LLMDebuggerApp"
        ),
        // 独立测试运行器：`swift run LLMDebuggerTests`
        .executableTarget(
            name: "LLMDebuggerTests",
            dependencies: ["LLMDebuggerCore"],
            path: "Tests/LLMDebuggerTests"
        )
    ]
)
