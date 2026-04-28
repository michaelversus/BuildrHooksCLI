@testable import BuildrHooksCore
import Foundation
import Testing

struct BuildrHooksCLIEntrypointTests {
    @Test
    func codexIngestWritesRawEventAndPostsNotification() throws {
        let repositoryRoot = try temporaryDirectory(named: "entrypoint")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        FileManager.default.createFile(atPath: repositoryRoot.appending(path: ".git").path, contents: Data())
        let notifier = HookEventNotifierSpy()
        let stderr = LockedMessages()
        let queue = RawHookEventQueue(
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            makeID: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
        )
        let payload = #"{"session_id":"session-42","transcript_path":"/tmp/session-42.jsonl","model":"gpt-5"}"#

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
        #expect(event.repositoryRootPath == repositoryRoot.path)
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

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BuildrHooksCLI-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
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
