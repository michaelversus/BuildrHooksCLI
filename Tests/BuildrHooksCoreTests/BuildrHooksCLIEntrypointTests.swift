@testable import BuildrHooksCore
import Foundation
import Testing

struct BuildrHooksCLIEntrypointTests { // swiftlint:disable:this type_body_length
    @Test
    func codexIngestWritesRawEventAndPostsNotification() throws {
        let repositoryRoot = try temporaryDirectory(named: "entrypoint")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        try createGitFixture(at: repositoryRoot)
        let notifier = HookEventNotifierSpy()
        let stderr = LockedMessages()
        let queue = RawHookEventQueue(
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeID: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
        )
        let payload = """
        {"session_id":"session-42","transcript_path":"/tmp/session-42.jsonl",\
        "model":"gpt-5","turn_id":"turn-42"}
        """

        let entrypoint = BuildrHooksCLIEntrypoint(
            standardInputProvider: { Data(payload.utf8) },
            standardErrorWriter: { stderr.append($0) },
            currentWorkingDirectoryProvider: { repositoryRoot.path },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            repositoryRootLocator: RepositoryRootLocator(),
            queue: queue,
            notifier: notifier
        )

        try entrypoint.run(arguments: ["buildrhooks", "codex", "session-start"])

        let queueDirectory = repositoryRoot.appending(path: ".buildrai/inbox/raw-hooks")
        let files = try FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil)
        #expect(files.count == 1)

        let data = try Data(contentsOf: files[0])
        let event = try JSONDecoder.buildrHooksDecoder.decode(RawHookEvent.self, from: data)
        #expect(event.agentKind == .codex)
        #expect(event.eventKind == .sessionStart)
        #expect(event.sessionID == "session-42")
        #expect(event.transcriptPath == "/tmp/session-42.jsonl")
        #expect(event.payloadVersion == 2)
        #expect(event.turnID == "turn-42")
        #expect(event.repositoryRootPath == repositoryRoot.path)
        #expect(event.gitContext?.headSHA == "0123456789abcdef0123456789abcdef01234567")
        #expect(event.gitContext?.branchName == "main")
        #expect(event.repositoryFingerprint == event.gitContext?.repositoryFingerprint)
        #expect(notifier.repositoryRootPaths == [repositoryRoot.path])
        #expect(stderr.messages.isEmpty)
    }

    @Test
    func parseFailureLogsButDoesNotThrow() throws {
        let repositoryRoot = try temporaryDirectory(named: "entrypoint-parse-failure")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        FileManager.default.createFile(atPath: repositoryRoot.appending(path: ".git").path, contents: Data())
        let notifier = HookEventNotifierSpy()
        let stderr = LockedMessages()
        let entrypoint = BuildrHooksCLIEntrypoint(
            standardInputProvider: { Data("not-json".utf8) },
            standardErrorWriter: { stderr.append($0) },
            currentWorkingDirectoryProvider: { repositoryRoot.path },
            repositoryRootLocator: RepositoryRootLocator(),
            queue: RawHookEventQueue(),
            notifier: notifier
        )

        try entrypoint.run(arguments: ["buildrhooks", "codex", "session-start"])

        let queueDirectory = repositoryRoot.appending(path: ".buildrai/inbox/raw-hooks")
        let files = try? FileManager.default.contentsOfDirectory(at: queueDirectory, includingPropertiesForKeys: nil)
        #expect(files?.isEmpty ?? true)
        #expect(stderr.messages.count == 1)
        #expect(stderr.messages[0].contains("BuildrHooksCLI warning:"))
        #expect(notifier.repositoryRootPaths.isEmpty)
    }

    @Test
    func taggedPromptWithMissingMarkerExitsSetupErrorAndDoesNotEnqueue() throws {
        let repositoryRoot = try temporaryDirectory(named: "prompt-gate-missing-marker")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try createGitFixture(at: repositoryRoot)

        let stderr = LockedMessages()
        let entrypoint = try makePromptSubmitEntrypoint(
            repositoryRoot: repositoryRoot,
            prompt: "#BuildrAI-Eval\nShip it.",
            stderr: stderr
        )

        do {
            try entrypoint.run(arguments: ["buildrhooks", "codex", "prompt-submit"])
            Issue.record("Expected Prompt Gate exit.")
        } catch let exit as PromptGateExit {
            #expect(exit.code == .unavailable)
        }

        #expect(rawHookFiles(in: repositoryRoot).isEmpty)
        #expect(stderr.messages.first?.contains("Prompt Gate is not enabled") == true)
    }

    @Test
    func taggedPromptWithMalformedMarkerExitsInvalidConfigurationAndDoesNotEnqueue() throws {
        let repositoryRoot = try temporaryDirectory(named: "prompt-gate-malformed-marker")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try createGitFixture(at: repositoryRoot)
        try createPromptGateMarkerDirectory(at: repositoryRoot)
        try "not-json".write(
            to: repositoryRoot.appending(path: ".buildrai/hooks/prompt-gate.json"),
            atomically: true,
            encoding: .utf8
        )

        let stderr = LockedMessages()
        let entrypoint = try makePromptSubmitEntrypoint(
            repositoryRoot: repositoryRoot,
            prompt: "#BuildrAI-Eval\nShip it.",
            stderr: stderr
        )

        do {
            try entrypoint.run(arguments: ["buildrhooks", "codex", "prompt-submit"])
            Issue.record("Expected Prompt Gate exit.")
        } catch let exit as PromptGateExit {
            #expect(exit.code == .invalidConfiguration)
        }

        #expect(rawHookFiles(in: repositoryRoot).isEmpty)
    }

    @Test
    func taggedPromptAllowedByResponseEnqueuesRawEventAndCleansHandshake() throws {
        let repositoryRoot = try temporaryDirectory(named: "prompt-gate-allow")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try createGitFixture(at: repositoryRoot)
        try writeEnabledPromptGateMarker(at: repositoryRoot)
        let clock = LockedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let requestID = try #require(UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        let stderr = LockedMessages()
        let promptGate = PromptGate(
            now: { clock.now },
            makeRequestID: { requestID },
            sleep: { _ in
                try? writePromptGateResponse(
                    repositoryRoot: repositoryRoot,
                    requestID: requestID.uuidString.lowercased(),
                    decision: "allow"
                )
                clock.advance(by: 0.1)
            },
            timeout: 1,
            pollingInterval: 0.1
        )
        let entrypoint = try makePromptSubmitEntrypoint(
            repositoryRoot: repositoryRoot,
            prompt: "#BuildrAI-Eval\nShip it.",
            stderr: stderr,
            promptGate: promptGate
        )

        try entrypoint.run(arguments: ["buildrhooks", "codex", "prompt-submit"])

        #expect(rawHookFiles(in: repositoryRoot).count == 1)
        #expect(!FileManager.default.fileExists(atPath: promptEvalPath(repositoryRoot, "inflight.lock").path))
        #expect(!FileManager.default.fileExists(atPath: promptEvalPath(repositoryRoot, "request.json").path))
        #expect(!FileManager.default.fileExists(atPath: promptEvalPath(repositoryRoot, "response.json").path))
        #expect(stderr.messages.isEmpty)
    }

    @Test
    func taggedPromptDeniedByResponseDoesNotEnqueue() throws {
        let repositoryRoot = try temporaryDirectory(named: "prompt-gate-deny")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try createGitFixture(at: repositoryRoot)
        try writeEnabledPromptGateMarker(at: repositoryRoot)
        let clock = LockedClock(Date(timeIntervalSince1970: 1_700_000_000))
        let requestID = try #require(UUID(uuidString: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE"))

        let stderr = LockedMessages()
        let promptGate = PromptGate(
            now: { clock.now },
            makeRequestID: { requestID },
            sleep: { _ in
                try? writePromptGateResponse(
                    repositoryRoot: repositoryRoot,
                    requestID: requestID.uuidString.lowercased(),
                    decision: "deny",
                    reason: "Too risky."
                )
                clock.advance(by: 0.1)
            },
            timeout: 1,
            pollingInterval: 0.1
        )
        let entrypoint = try makePromptSubmitEntrypoint(
            repositoryRoot: repositoryRoot,
            prompt: "#BuildrAI-Eval\nShip it.",
            stderr: stderr,
            promptGate: promptGate
        )

        do {
            try entrypoint.run(arguments: ["buildrhooks", "codex", "prompt-submit"])
            Issue.record("Expected Prompt Gate denial.")
        } catch let exit as PromptGateExit {
            #expect(exit.code == .denied)
        }

        #expect(rawHookFiles(in: repositoryRoot).isEmpty)
        #expect(stderr.messages.first?.contains("Too risky.") == true)
    }

    @Test
    func oversizedTaggedPromptCreatesNoHandshakeFiles() throws {
        let repositoryRoot = try temporaryDirectory(named: "prompt-gate-oversized")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try createGitFixture(at: repositoryRoot)
        try writeEnabledPromptGateMarker(at: repositoryRoot)

        let stderr = LockedMessages()
        let entrypoint = try makePromptSubmitEntrypoint(
            repositoryRoot: repositoryRoot,
            prompt: "#BuildrAI-Eval\n123456",
            stderr: stderr,
            promptGate: PromptGate(promptCharacterLimit: 5)
        )

        do {
            try entrypoint.run(arguments: ["buildrhooks", "codex", "prompt-submit"])
            Issue.record("Expected Prompt Gate size failure.")
        } catch let exit as PromptGateExit {
            #expect(exit.code == .promptTooLarge)
        }

        #expect(!FileManager.default.fileExists(atPath: promptEvalPath(repositoryRoot, "inflight.lock").path))
        #expect(!FileManager.default.fileExists(atPath: promptEvalPath(repositoryRoot, "request.json").path))
        #expect(rawHookFiles(in: repositoryRoot).isEmpty)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BuildrHooksCLI-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createGitFixture(at repositoryRoot: URL) throws {
        let gitDirectory = repositoryRoot.appending(path: ".git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: gitDirectory.appending(path: "refs/heads", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try "ref: refs/heads/main\n".write(
            to: gitDirectory.appending(path: "HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "0123456789abcdef0123456789abcdef01234567\n".write(
            to: gitDirectory.appending(path: "refs/heads/main"),
            atomically: true,
            encoding: .utf8
        )
    }

    private func makePromptSubmitEntrypoint(
        repositoryRoot: URL,
        prompt: String,
        stderr: LockedMessages,
        promptGate: PromptGate = .init(timeout: 0, pollingInterval: 0)
    ) throws -> BuildrHooksCLIEntrypoint {
        let payload = try """
        {"session_id":"session-42","transcript_path":"/tmp/session-42.jsonl",\
        "prompt":\(jsonString(prompt)),"model":"gpt-5","turn_id":"turn-42"}
        """
        return BuildrHooksCLIEntrypoint(
            standardInputProvider: { Data(payload.utf8) },
            standardErrorWriter: { stderr.append($0) },
            currentWorkingDirectoryProvider: { repositoryRoot.path },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            repositoryRootLocator: RepositoryRootLocator(),
            queue: RawHookEventQueue(
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                makeID: { UUID(uuidString: "CCCCCCCC-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
            ),
            notifier: HookEventNotifierSpy(),
            promptGate: promptGate
        )
    }

    private func rawHookFiles(in repositoryRoot: URL) -> [URL] {
        let queueDirectory = repositoryRoot.appending(path: ".buildrai/inbox/raw-hooks")
        return (try? FileManager.default.contentsOfDirectory(
            at: queueDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
    }

    private func createPromptGateMarkerDirectory(at repositoryRoot: URL) throws {
        try FileManager.default.createDirectory(
            at: repositoryRoot.appending(path: ".buildrai/hooks", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    private func writeEnabledPromptGateMarker(at repositoryRoot: URL) throws {
        try createPromptGateMarkerDirectory(at: repositoryRoot)
        try #"{"version":1,"enabled":true,"project_id":"project-42"}"#.write(
            to: repositoryRoot.appending(path: ".buildrai/hooks/prompt-gate.json"),
            atomically: true,
            encoding: .utf8
        )
    }
}

private func promptEvalPath(_ repositoryRoot: URL, _ component: String) -> URL {
    repositoryRoot.appending(path: ".buildrai/hooks/prompt-eval/\(component)")
}

private func writePromptGateResponse(
    repositoryRoot: URL,
    requestID: String,
    decision: String,
    reason: String? = nil
) throws {
    let responseURL = promptEvalPath(repositoryRoot, "response.json")
    guard !FileManager.default.fileExists(atPath: responseURL.path) else {
        return
    }
    let reasonField: String = if let reason {
        try #","reason":\#(jsonString(reason))"#
    } else {
        ""
    }
    let payload = #"{"version":1,"request_id":"\#(requestID)","decision":"\#(decision)"\#(reasonField)}"#
    try payload.write(to: responseURL, atomically: true, encoding: .utf8)
}

private func jsonString(_ string: String) throws -> String {
    let data = try JSONEncoder().encode(string)
    return try #require(String(data: data, encoding: .utf8))
}

private final class LockedClock: @unchecked Sendable {
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

private final class HookEventNotifierSpy: HookEventNotifying, @unchecked Sendable {
    private(set) var repositoryRootPaths: [String] = []

    func postHookEventEnqueued(repositoryRootPath: String) {
        repositoryRootPaths.append(repositoryRootPath)
    }
}

private final class LockedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var messages: [String] = []

    func append(_ message: String) {
        lock.lock()
        messages.append(message)
        lock.unlock()
    }
}

private extension JSONDecoder {
    static var buildrHooksDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
