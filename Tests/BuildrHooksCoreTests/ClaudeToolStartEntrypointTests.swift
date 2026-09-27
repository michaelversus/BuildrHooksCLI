@testable import BuildrHooksCore
import Foundation
import Testing

struct ClaudeToolStartEntrypointTests {
    @Test
    func toolStartEnqueuesContentFreeEventAndNotifies() throws {
        let repositoryRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try FileManager.default.createDirectory(
            at: repositoryRoot.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let notifier = HookEventNotifierSpy()
        let stderr = LockedMessages()
        let payload = #"""
        {"session_id":"session-42","tool_name":"Bash","tool_use_id":"toolu_42","agent_id":"agent-42",
         "tool_input":{"command":"PRIVATE_COMMAND_SENTINEL"},
         "tool_response":"PRIVATE_OUTPUT_SENTINEL"}
        """#
        let entrypoint = BuildrHooksCLIEntrypoint(
            standardInputProvider: { Data(payload.utf8) },
            standardErrorWriter: { stderr.append($0) },
            currentWorkingDirectoryProvider: { repositoryRoot.path },
            now: { Date(timeIntervalSince1970: 1_700_000_000) },
            queue: RawHookEventQueue(
                now: { Date(timeIntervalSince1970: 1_700_000_000) },
                makeID: { UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")! }
            ),
            notifier: notifier
        )

        try entrypoint.run(arguments: ["buildrhooks", "claude", "tool-start"])

        let files = try rawHookFiles(in: repositoryRoot)
        #expect(files.count == 1)
        let data = try Data(contentsOf: files[0])
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["schema_version"] as? Int == 1)
        #expect(json["event_type"] as? String == "tool_start")
        #expect(json["source"] as? String == "claude")
        #expect(json["session_id"] as? String == "session-42")
        #expect(json["tool_name"] as? String == "Bash")
        #expect(json["timestamp"] as? String == "2023-11-14T22:13:20Z")
        #expect(json["invocation_id"] as? String == "toolu_42")
        #expect(json["subagent_id"] as? String == "agent-42")
        #expect(json["tool_input"] == nil)
        #expect(json["tool_response"] == nil)
        let encoded = try #require(String(bytes: data, encoding: .utf8))
        #expect(!encoded.contains("PRIVATE_COMMAND_SENTINEL"))
        #expect(!encoded.contains("PRIVATE_OUTPUT_SENTINEL"))
        #expect(notifier.repositoryRootPaths == [repositoryRoot.path])
        #expect(stderr.messages.isEmpty)
    }

    @Test
    func malformedToolStartWarnsAndFailsOpen() throws {
        let repositoryRoot = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try FileManager.default.createDirectory(
            at: repositoryRoot.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let notifier = HookEventNotifierSpy()
        let stderr = LockedMessages()
        let entrypoint = BuildrHooksCLIEntrypoint(
            standardInputProvider: { Data("not-json".utf8) },
            standardErrorWriter: { stderr.append($0) },
            currentWorkingDirectoryProvider: { repositoryRoot.path },
            queue: RawHookEventQueue(),
            notifier: notifier
        )

        try entrypoint.run(arguments: ["buildrhooks", "claude", "tool-start"])

        #expect(try rawHookFiles(in: repositoryRoot).isEmpty)
        #expect(stderr.messages.count == 1)
        #expect(stderr.messages[0].contains("BuildrHooksCLI warning:"))
        #expect(notifier.repositoryRootPaths.isEmpty)
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "claude-tool-start-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func rawHookFiles(in repositoryRoot: URL) throws -> [URL] {
        let directory = repositoryRoot.appending(path: ".buildrai/inbox/raw-hooks")
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
}
