@testable import BuildrHooksCore
import Foundation
import Testing

struct RawHookEventQueueTests {
    @Test
    func enqueueCreatesRawHookEventUnderRepoLocalQueue() throws {
        let rootURL = try temporaryDirectory(named: "raw-hook-queue")
        defer { try? FileManager.default.removeItem(at: rootURL) }

        let queue = RawHookEventQueue(
            now: { Date(timeIntervalSince1970: 1_777_777_777) },
            makeID: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
        )
        let event = RawHookEvent(
            agentKind: .codex,
            eventKind: .sessionStart,
            createdAt: Date(timeIntervalSince1970: 1_777_777_777),
            currentWorkingDirectory: rootURL.path,
            repositoryRootPath: rootURL.path,
            sessionID: "session-123",
            transcriptPath: "/tmp/transcript.jsonl",
            model: "gpt-test",
            rawPayload: #"{"session_id":"session-123"}"#
        )

        let fileURL = try queue.enqueue(event, in: rootURL)

        let expectedQueuePath = rootURL.appending(path: ".buildrai/inbox/raw-hooks").path
        let expectedArchivePath = rootURL.appending(path: ".buildrai/archive/raw-hooks-processed").path
        #expect(fileURL.deletingLastPathComponent().path == expectedQueuePath)
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(FileManager.default.fileExists(atPath: expectedArchivePath))

        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(RawHookEvent.self, from: data)
        #expect(decoded == event)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BuildrHooksCLI-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
