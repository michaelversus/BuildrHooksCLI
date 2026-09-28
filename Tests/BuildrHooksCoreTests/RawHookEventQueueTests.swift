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

    @Test
    func enqueueWritesVersionMarkerAtomicallyForRepositoryPathWithSpaces() throws {
        let rootURL = try temporaryDirectory(named: "repo with spaces")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let queue = RawHookEventQueue(bridgeCLIVersion: "1.2.3")

        _ = try queue.enqueue(event(at: rootURL), in: rootURL)

        let markerURL = rootURL.appending(path: ".buildrai/bridge-cli-version.json")
        let markerData = try Data(contentsOf: markerURL)
        let marker = try JSONDecoder().decode(BridgeCLIVersionMarkerTestValue.self, from: markerData)
        #expect(marker.version == "1.2.3")
        #expect(FileManager.default.fileExists(atPath: markerURL.path))

        _ = try queue.enqueue(event(at: rootURL), in: rootURL)
        #expect(try Data(contentsOf: markerURL) == markerData)
        #expect(try FileManager.default.contentsOfDirectory(
            at: markerURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).count(where: { $0.lastPathComponent.contains("bridge-cli-version") }) == 1)
    }

    @Test
    func enqueueOverwritesChangedVersionAndRepairsAbsentOrMalformedMarker() throws {
        let rootURL = try temporaryDirectory(named: "version-marker-repair")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let markerURL = rootURL.appending(path: ".buildrai/bridge-cli-version.json")

        _ = try RawHookEventQueue(bridgeCLIVersion: "1.2.2").enqueue(event(at: rootURL), in: rootURL)
        #expect(try version(in: markerURL) == "1.2.2")

        _ = try RawHookEventQueue(bridgeCLIVersion: "1.2.3").enqueue(event(at: rootURL), in: rootURL)
        #expect(try version(in: markerURL) == "1.2.3")

        try Data("not-json".utf8).write(to: markerURL)
        _ = try RawHookEventQueue(bridgeCLIVersion: "1.2.4").enqueue(event(at: rootURL), in: rootURL)
        #expect(try version(in: markerURL) == "1.2.4")

        try FileManager.default.removeItem(at: markerURL)
        _ = try RawHookEventQueue(bridgeCLIVersion: "1.2.5").enqueue(event(at: rootURL), in: rootURL)
        #expect(try version(in: markerURL) == "1.2.5")
    }

    @Test
    func failedEnqueueLeavesPreviousVersionMarkerIntact() throws {
        let rootURL = try temporaryDirectory(named: "version-marker-enqueue-failure")
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let markerURL = rootURL.appending(path: ".buildrai/bridge-cli-version.json")
        try FileManager.default.createDirectory(
            at: markerURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"{"version":"1.2.2"}"#.write(to: markerURL, atomically: true, encoding: .utf8)

        let rawHooksPath = rootURL.appending(path: ".buildrai/inbox/raw-hooks")
        try Data("not a directory".utf8).write(to: rawHooksPath.deletingLastPathComponent().appending(path: "inbox"))
        let queue = RawHookEventQueue(bridgeCLIVersion: "1.2.3")

        #expect(throws: (any Error).self) {
            try queue.enqueue(event(at: rootURL), in: rootURL)
        }
        #expect(try version(in: markerURL) == "1.2.2")
    }

    private func event(at rootURL: URL) -> RawHookEvent {
        RawHookEvent(
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
    }

    private func version(in markerURL: URL) throws -> String {
        try JSONDecoder().decode(BridgeCLIVersionMarkerTestValue.self, from: Data(contentsOf: markerURL)).version
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BuildrHooksCLI-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

private struct BridgeCLIVersionMarkerTestValue: Decodable {
    let version: String
}
