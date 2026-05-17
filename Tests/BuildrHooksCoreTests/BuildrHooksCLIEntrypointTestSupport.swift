@testable import BuildrHooksCore
import Foundation
import Testing

func promptEvalPath(_ repositoryRoot: URL, _ component: String) -> URL {
    repositoryRoot.appending(path: ".buildrai/hooks/prompt-eval/\(component)")
}

func writePromptGateResponse(
    repositoryRoot: URL,
    requestID: String,
    decision: String,
    reason: String? = nil,
    failureCategory: String? = nil,
    suggestedPrompt: String? = nil,
    score: Int? = nil,
    label: String? = nil,
    confidence: String? = nil
) throws {
    let responseURL = promptEvalPath(repositoryRoot, "response.json")
    guard !FileManager.default.fileExists(atPath: responseURL.path) else {
        return
    }
    var fields = [
        #""version":1"#,
        #""request_id":"\#(requestID)""#,
        #""decision":"\#(decision)""#
    ]
    if let reason {
        try fields.append(#""reason":\#(jsonString(reason))"#)
    }
    if let failureCategory {
        try fields.append(#""failure_category":\#(jsonString(failureCategory))"#)
    }
    if let suggestedPrompt {
        try fields.append(#""suggested_prompt":\#(jsonString(suggestedPrompt))"#)
    }
    if let score {
        fields.append(#""score":\#(score)"#)
    }
    if let label {
        try fields.append(#""label":\#(jsonString(label))"#)
    }
    if let confidence {
        try fields.append(#""confidence":\#(jsonString(confidence))"#)
    }
    let payload = "{\(fields.joined(separator: ","))}"
    try payload.write(to: responseURL, atomically: true, encoding: .utf8)
}

func jsonString(_ string: String) throws -> String {
    let data = try JSONEncoder().encode(string)
    return try #require(String(data: data, encoding: .utf8))
}

final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return date
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        date = date.addingTimeInterval(interval)
        lock.unlock()
    }
}

final class HookEventNotifierSpy: HookEventNotifying, @unchecked Sendable {
    private(set) var repositoryRootPaths: [String] = []

    func postHookEventEnqueued(repositoryRootPath: String) {
        repositoryRootPaths.append(repositoryRootPath)
    }
}

final class LockedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }
}

extension JSONDecoder {
    static var buildrHooksDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
