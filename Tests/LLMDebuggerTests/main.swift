import Foundation
import LLMDebuggerCore

@main
struct TestMain {
    @MainActor
    static func main() async {
        let suites: [(String, [MiniTest])] = [
            ("A. 服务地址解析", endpointResolverTests()),
            ("B. SSE 增量解析", sseParserTests()),
            ("C. chunk 解码", chunkDecoderTests()),
            ("D. think 标签路由", thinkTagRouterTests()),
            ("E. Token 估算", tokenEstimatorTests()),
            ("F. 推理速率统计", throughputMeterTests()),
            ("G. 日志仓库", logStoreTests()),
            ("H. 密钥脱敏", secretsTests()),
            ("I. 请求组装", requestBuilderTests()),
            ("J. 模型列表", modelsParsingTests()),
            ("K. 流式管道", streamPipelineTests()),
            ("L. 会话引擎", chatSessionTests()),
            ("M. 真实网络传输", urlSessionTransportTests())
        ]

        var passed = 0
        var failures: [String] = []
        let started = Date()

        for (suiteName, tests) in suites {
            print("\n== \(suiteName) ==")
            for test in tests {
                do {
                    try await test.body()
                    passed += 1
                    print("  PASS  \(test.name)")
                } catch {
                    failures.append("[\(suiteName)] \(test.name) -> \(error)")
                    print("  FAIL  \(test.name)")
                    print("        \(error)")
                }
            }
        }

        let elapsed = Date().timeIntervalSince(started)
        let total = passed + failures.count
        print("\n--------------------------------------------------")
        print("用例总数 \(total)，通过 \(passed)，失败 \(failures.count)，耗时 \(String(format: "%.2f", elapsed))s")
        if !failures.isEmpty {
            print("\n失败明细：")
            for item in failures { print(" - \(item)") }
            exit(1)
        }
        print("全部通过")
    }
}
