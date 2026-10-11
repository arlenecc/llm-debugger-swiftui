import Foundation
import LLMDebuggerCore

/// 用例组 C：chunk 解码（最终回复 / 思考过程 / 用量 / 错误）
@MainActor
func chunkDecoderTests() -> [MiniTest] {
    [
        MiniTest("C1 解码 content 为最终回复") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"choices":[{"delta":{"content":"你好"}}]}"#)
            try XCTAssertEqual(event?.answerDelta, "你好")
            try XCTAssertEqual(event?.thinkingDelta, "")
        },

        MiniTest("C2 解码 reasoning_content 为思考过程") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"choices":[{"delta":{"reasoning_content":"让我算算"}}]}"#)
            try XCTAssertEqual(event?.thinkingDelta, "让我算算")
            try XCTAssertEqual(event?.answerDelta, "")
        },

        MiniTest("C3 兼容 reasoning 字符串字段") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"choices":[{"delta":{"reasoning":"think..."}}]}"#)
            try XCTAssertEqual(event?.thinkingDelta, "think...")
        },

        MiniTest("C4 兼容 reasoning 对象字段") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"choices":[{"delta":{"reasoning":{"content":"obj-think"}}}]}"#)
            try XCTAssertEqual(event?.thinkingDelta, "obj-think")
        },

        MiniTest("C5 兼容 thinking 字段") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"choices":[{"delta":{"thinking":"t"}}]}"#)
            try XCTAssertEqual(event?.thinkingDelta, "t")
        },

        MiniTest("C6 非流式响应的 message 字段") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(
                #"{"choices":[{"message":{"role":"assistant","content":"答案","reasoning_content":"推理"},"finish_reason":"stop"}]}"#
            )
            try XCTAssertEqual(event?.answerDelta, "答案")
            try XCTAssertEqual(event?.thinkingDelta, "推理")
            try XCTAssertEqual(event?.finishReason, "stop")
        },

        MiniTest("C7 解析 usage") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(
                #"{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":22,"total_tokens":33}}"#
            )
            try XCTAssertEqual(event?.usage?.promptTokens, 11)
            try XCTAssertEqual(event?.usage?.completionTokens, 22)
            try XCTAssertEqual(event?.usage?.total, 33)
            try XCTAssertEqual(event?.usage?.estimated, false)
        },

        MiniTest("C8 解析 completion_tokens_details 中的推理 token") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(
                #"{"usage":{"completion_tokens":50,"completion_tokens_details":{"reasoning_tokens":40}}}"#
            )
            try XCTAssertEqual(event?.usage?.reasoningTokens, 40)
        },

        MiniTest("C9 空 choices 返回 nil") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"choices":[]}"#)
            try XCTAssertNil(event)
        },

        MiniTest("C10 非法 JSON 抛出错误") {
            let decoder = ChunkDecoder()
            try XCTAssertThrowsError(try decoder.decode("not-a-json")) { error in
                try XCTAssertTrue(error is ChunkDecodeError)
            }
        },

        MiniTest("C11 空负载返回 nil") {
            let decoder = ChunkDecoder()
            try XCTAssertNil(try decoder.decode(""))
            try XCTAssertNil(try decoder.decode("   \n "))
        },

        MiniTest("C12 服务端错误消息被捕获") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"error":{"message":"rate limit","type":"server_error"}}"#)
            try XCTAssertEqual(event?.errorMessage, "rate limit")
        },

        MiniTest("C13 error 为字符串也能捕获") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"error":"boom"}"#)
            try XCTAssertEqual(event?.errorMessage, "boom")
        },

        MiniTest("C14 finish_reason 被捕获") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"choices":[{"delta":{},"finish_reason":"length"}]}"#)
            try XCTAssertEqual(event?.finishReason, "length")
            try XCTAssertEqual(event?.answerDelta, "")
        },

        MiniTest("C15 model 字段被透传") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"model":"gpt-4o","choices":[{"delta":{"content":"x"}}]}"#)
            try XCTAssertEqual(event?.model, "gpt-4o")
        },

        MiniTest("C16 关闭标签路由时 content 全部进最终回复") {
            let decoder = ChunkDecoder(routeThinkTags: false)
            let event = try decoder.decode(#"{"choices":[{"delta":{"content":"<think>a</think>b"}}]}"#)
            try XCTAssertEqual(event?.answerDelta, "<think>a</think>b")
            try XCTAssertEqual(event?.thinkingDelta, "")
        },

        MiniTest("C17 多个 choice 只取第一个") {
            let decoder = ChunkDecoder()
            let event = try decoder.decode(#"{"choices":[{"delta":{"content":"A"}},{"delta":{"content":"B"}}]}"#)
            try XCTAssertEqual(event?.answerDelta, "A")
        }
    ]
}

/// 用例组 D：`<think>` 标签路由
@MainActor
func thinkTagRouterTests() -> [MiniTest] {
    [
        MiniTest("D1 完整标签一次到达") {
            var router = ThinkTagRouter()
            let result = router.route("<think>思考</think>答案")
            try XCTAssertEqual(result.thinking, "思考")
            try XCTAssertEqual(result.answer, "答案")
        },

        MiniTest("D2 标签被 chunk 边界切断") {
            var router = ThinkTagRouter()
            var thinking = ""
            var answer = ""
            for piece in ["<thi", "nk>思", "考</thi", "nk>", "答案"] {
                let r = router.route(piece)
                thinking += r.thinking
                answer += r.answer
            }
            try XCTAssertEqual(thinking, "思考")
            try XCTAssertEqual(answer, "答案")
        },

        MiniTest("D3 未闭合的思考段在流结束时完整保留") {
            var router = ThinkTagRouter()
            var thinking = ""
            var answer = ""
            for piece in ["<think>", "还没", "想完"] {
                let r = router.route(piece)
                thinking += r.thinking
                answer += r.answer
            }
            let flushed = router.finish()
            thinking += flushed.thinking
            answer += flushed.answer
            try XCTAssertEqual(thinking, "还没想完")
            try XCTAssertEqual(answer, "")
        },

        MiniTest("D4 无标签时全部作为回复") {
            var router = ThinkTagRouter()
            let result = router.route("直接回答")
            try XCTAssertEqual(result.answer, "直接回答")
            try XCTAssertEqual(result.thinking, "")
        },

        MiniTest("D5 大小写不敏感") {
            var router = ThinkTagRouter()
            let result = router.route("<THINK>a</ThInK>b")
            try XCTAssertEqual(result.thinking, "a")
            try XCTAssertEqual(result.answer, "b")
        },

        MiniTest("D6 支持 thinking 长标签") {
            var router = ThinkTagRouter()
            let result = router.route("<thinking>x</thinking>y")
            try XCTAssertEqual(result.thinking, "x")
            try XCTAssertEqual(result.answer, "y")
        },

        MiniTest("D7 多轮思考段落") {
            var router = ThinkTagRouter()
            let result = router.route("前<think>一</think>中<think>二</think>后")
            try XCTAssertEqual(result.thinking, "一二")
            try XCTAssertEqual(result.answer, "前中后")
        },

        MiniTest("D8 中文不会被截断") {
            var router = ThinkTagRouter()
            var answer = ""
            for char in "你好世界" {
                answer += router.route(String(char)).answer
            }
            try XCTAssertEqual(answer, "你好世界")
        },

        MiniTest("D9 状态可重置") {
            var router = ThinkTagRouter()
            _ = router.route("<think>x")
            router.reset()
            let result = router.route("y")
            try XCTAssertEqual(result.answer, "y")
            try XCTAssertFalse(router.isInsideThink)
        },

        MiniTest("D10 思考过程中的内容不会泄漏到回复") {
            var router = ThinkTagRouter()
            var answer = ""
            var thinking = ""
            for piece in ["<think>", "a", "b", "</think>", "c"] {
                let r = router.route(piece)
                thinking += r.thinking
                answer += r.answer
            }
            try XCTAssertEqual(thinking, "ab")
            try XCTAssertEqual(answer, "c")
        }
    ]
}
