@testable import BuildrHooksCore
import Foundation
import Testing

struct ClaudeCompanionTests {
    @Test
    func resolverDeclaresDesktopForLatestMatchingClaudeDesktopEntrypoint() {
        let transcript = #"""
        {"sessionId":"session-42","entrypoint":"cli"}
        {"sessionId":"other-session","entrypoint":"claude-desktop"}
        {"sessionId":"session-42","entrypoint":"claude-desktop"}
        """#

        let surface = resolver(for: transcript).resolveClaudeDesktopSurface(
            transcriptPath: "/tmp/session-42.jsonl",
            sessionID: "session-42"
        )

        #expect(surface == ExecutionSurface(kind: .desktop, instanceID: "claude-session:session-42"))
    }

    @Test(arguments: [
        #"{"sessionId":"session-42","entrypoint":"cli"}"#,
        #"{"sessionId":"other-session","entrypoint":"claude-desktop"}"#,
        #"{"sessionId":"session-42"}"#,
        "not-json"
    ])
    func resolverLeavesUnprovenOrMismatchedSurfaceUnavailable(transcript: String) {
        #expect(resolver(for: transcript).resolveClaudeDesktopSurface(
            transcriptPath: "/tmp/session-42.jsonl",
            sessionID: "session-42"
        ) == nil)
    }

    @Test
    func resolverUsesLatestEntrypointWhenSessionMovesToTerminal() {
        let transcript = #"""
        {"sessionId":"session-42","entrypoint":"claude-desktop"}
        {"sessionId":"session-42","entrypoint":"cli"}
        """#

        #expect(resolver(for: transcript).resolveClaudeDesktopSurface(
            transcriptPath: "/tmp/session-42.jsonl",
            sessionID: "session-42"
        ) == nil)
    }

    @Test
    func claudeLifecycleEventsEnqueuePromptAndResolvedSurfaceWithoutPromptGate() throws {
        let repositoryRoot = try temporaryDirectory(named: "claude-companion")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }
        try createGitFixture(at: repositoryRoot)

        let transcriptURL = repositoryRoot.appending(path: "session-42.jsonl")
        try #"{"sessionId":"session-42","entrypoint":"claude-desktop"}"#.write(
            to: transcriptURL,
            atomically: true,
            encoding: .utf8
        )
        let payloads: [(HookEventKind, String)] = [
            (.sessionStart, #"{"session_id":"session-42","transcript_path":"TRANSCRIPT_PATH","model":"claude-opus"}"#),
            (
                .promptSubmit,
                #"""
                {"session_id":"session-42","transcript_path":"TRANSCRIPT_PATH",
                "prompt":"#BuildrAI-Eval\nShip it."}
                """#
            ),
            (.stop, #"{"session_id":"session-42","transcript_path":"TRANSCRIPT_PATH"}"#)
        ]

        for (kind, template) in payloads {
            let payload = template.replacingOccurrences(of: "TRANSCRIPT_PATH", with: transcriptURL.path)
            let entrypoint = BuildrHooksCLIEntrypoint(
                standardInputProvider: { Data(payload.utf8) },
                currentWorkingDirectoryProvider: { repositoryRoot.path },
                queue: RawHookEventQueue(),
                notifier: HookEventNotifierSpy()
            )
            try entrypoint.run(arguments: ["buildrhooks", "claude", kind.rawValue])
        }

        let events = try rawHookFiles(in: repositoryRoot).map {
            try JSONDecoder.buildrHooksDecoder.decode(RawHookEvent.self, from: Data(contentsOf: $0))
        }
        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.agentKind == .claude })
        #expect(events.allSatisfy {
            $0.executionSurface == ExecutionSurface(kind: .desktop, instanceID: "claude-session:session-42")
        })
        let promptEvent = try #require(events.first { $0.eventKind == .promptSubmit })
        #expect(promptEvent.rawPayload.contains("#BuildrAI-Eval"))
        #expect(promptEvent.model == nil)
    }

    @Test
    func capabilitiesAdvertiseClaudeLifecycleAndDesktopResolver() {
        #expect(BuildrHooksCapabilities.current.agents.contains(.claude))
        #expect(BuildrHooksCapabilities.current.lifecycleEvents == [.sessionStart, .promptSubmit, .stop])
        #expect(BuildrHooksCapabilities.current.claudeDesktopTranscriptSurfaceResolver)
    }

    private func resolver(for transcript: String) -> ClaudeTranscriptExecutionSurfaceResolver {
        ClaudeTranscriptExecutionSurfaceResolver(readFile: { _ in Data(transcript.utf8) })
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "BuildrHooksCLI-\(name)-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func createGitFixture(at repositoryRoot: URL) throws {
        try FileManager.default.createDirectory(
            at: repositoryRoot.appending(path: ".git", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
    }

    private func rawHookFiles(in repositoryRoot: URL) throws -> [URL] {
        let directory = repositoryRoot.appending(path: ".buildrai/inbox/raw-hooks", directoryHint: .isDirectory)
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
    }
}
