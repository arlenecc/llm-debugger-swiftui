import Foundation

// MARK: - 轻量断言库
// 当前工具链只安装了 Command Line Tools（无 XCTest），这里提供等价的断言能力。

public struct TestFailure: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

private func location(_ file: String, _ line: UInt) -> String {
    let name = (file as NSString).lastPathComponent
    return "(\(name):\(line))"
}

public func XCTAssertTrue(_ condition: Bool,
                          _ message: String = "",
                          file: String = #file,
                          line: UInt = #line) throws {
    guard condition else {
        throw TestFailure("\(location(file, line)) 期望为 true，实际为 false \(message)")
    }
}

public func XCTAssertFalse(_ condition: Bool,
                           _ message: String = "",
                           file: String = #file,
                           line: UInt = #line) throws {
    guard !condition else {
        throw TestFailure("\(location(file, line)) 期望为 false，实际为 true \(message)")
    }
}

public func XCTAssertEqual<T: Equatable>(_ actual: T,
                                         _ expected: T,
                                         _ message: String = "",
                                         file: String = #file,
                                         line: UInt = #line) throws {
    guard actual == expected else {
        throw TestFailure("\(location(file, line)) 期望 <\(expected)>，实际 <\(actual)> \(message)")
    }
}

public func XCTAssertEqual(_ actual: Double,
                           _ expected: Double,
                           accuracy: Double,
                           _ message: String = "",
                           file: String = #file,
                           line: UInt = #line) throws {
    guard abs(actual - expected) <= accuracy else {
        throw TestFailure("\(location(file, line)) 期望 <\(expected)> ±\(accuracy)，实际 <\(actual)> \(message)")
    }
}

public func XCTAssertNotEqual<T: Equatable>(_ actual: T,
                                            _ expected: T,
                                            _ message: String = "",
                                            file: String = #file,
                                            line: UInt = #line) throws {
    guard actual != expected else {
        throw TestFailure("\(location(file, line)) 期望不等于 <\(expected)> \(message)")
    }
}

public func XCTAssertNil<T>(_ value: T?,
                            _ message: String = "",
                            file: String = #file,
                            line: UInt = #line) throws {
    guard value == nil else {
        throw TestFailure("\(location(file, line)) 期望为 nil，实际 <\(value!)> \(message)")
    }
}

public func XCTAssertNotNil<T>(_ value: T?,
                               _ message: String = "",
                               file: String = #file,
                               line: UInt = #line) throws {
    guard value != nil else {
        throw TestFailure("\(location(file, line)) 期望非 nil \(message)")
    }
}

public func XCTAssertGreaterThan<T: Comparable>(_ lhs: T,
                                                _ rhs: T,
                                                _ message: String = "",
                                                file: String = #file,
                                                line: UInt = #line) throws {
    guard lhs > rhs else {
        throw TestFailure("\(location(file, line)) 期望 <\(lhs)> > <\(rhs)> \(message)")
    }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(_ lhs: T,
                                                    _ rhs: T,
                                                    _ message: String = "",
                                                    file: String = #file,
                                                    line: UInt = #line) throws {
    guard lhs <= rhs else {
        throw TestFailure("\(location(file, line)) 期望 <\(lhs)> <= <\(rhs)> \(message)")
    }
}

public func XCTFail(_ message: String = "",
                    file: String = #file,
                    line: UInt = #line) throws {
    throw TestFailure("\(location(file, line)) 直接失败 \(message)")
}

public func XCTAssertThrowsError<T>(_ expression: @autoclosure () throws -> T,
                                    _ message: String = "",
                                    file: String = #file,
                                    line: UInt = #line,
                                    _ verify: (Error) throws -> Void = { _ in }) throws {
    do {
        let value = try expression()
        throw TestFailure("\(location(file, line)) 期望抛出异常，但返回 <\(value)> \(message)")
    } catch let failure as TestFailure {
        throw failure
    } catch {
        try verify(error)
    }
}

public func XCTAssertNoThrow<T>(_ expression: @autoclosure () throws -> T,
                                _ message: String = "",
                                file: String = #file,
                                line: UInt = #line) throws {
    do {
        _ = try expression()
    } catch {
        throw TestFailure("\(location(file, line)) 期望不抛异常，但抛出 <\(error)> \(message)")
    }
}

// MARK: - 用例容器

public struct MiniTest {
    public let name: String
    public let body: @MainActor () async throws -> Void

    public init(_ name: String, body: @escaping @MainActor () async throws -> Void) {
        self.name = name
        self.body = body
    }
}
