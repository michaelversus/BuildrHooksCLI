@testable import BuildrHooksCore
import Foundation
import Testing

struct CodexTranscriptSurfaceTests {
    @Test
    func resolveDeclaresTerminalForKnownCLIOrigin() {
        let surface = resolver(for: Self.cliFixture).resolve(
            transcriptPath: "/tmp/transcript.jsonl",
            sessionID: "session-42"
        )

        #expect(surface == CodexExecutionSurface(kind: .terminal, instanceID: "codex-session:session-42"))
    }

    @Test(arguments: undeclaredFixtures)
    func resolveLeavesUnknownOrUnsupportedOriginsUnavailable(fixture: String) {
        let surface = resolver(for: fixture).resolve(
            transcriptPath: "/tmp/transcript.jsonl",
            sessionID: "session-42"
        )

        #expect(surface == nil)
    }

    @Test
    func resolveLeavesMissingOrUnreadableTranscriptsUnavailable() {
        #expect(CodexTranscriptExecutionSurfaceResolver(readFile: { _ in nil }).resolve(
            transcriptPath: "/tmp/missing.jsonl",
            sessionID: "session-42"
        ) == nil)
        #expect(resolver(for: Self.cliFixture).resolve(transcriptPath: nil, sessionID: "session-42") == nil)
    }

    private func resolver(for fixture: String) -> CodexTranscriptExecutionSurfaceResolver {
        CodexTranscriptExecutionSurfaceResolver(readFile: { _ in Data(fixture.utf8) })
    }

    private static let cliFixture = #"""
    {"type":"response","payload":{"text":"ignored"}}
    {"type":"session_meta","payload":{"session_id":"session-42","originator":"codex_cli_rs","source":"cli"}}
    """#

    private static let undeclaredFixtures = [
        sessionMeta("""
        "session_id":"session-42","originator":"Codex Desktop","source":"vscode"
        """),
        sessionMeta("""
        "session_id":"session-42","originator":"Codex Desktop","source":"subagent"
        """),
        sessionMeta("""
        "session_id":"session-42","originator":"codex_work_desktop","source":"vscode"
        """),
        sessionMeta("""
        "session_id":"session-42","originator":"other","source":"cli"
        """),
        sessionMeta("""
        "session_id":"other-session","originator":"codex_cli_rs","source":"cli"
        """),
        sessionMeta("""
        "session_id":"session-42","originator":"codex_cli_rs","source":{"subagent":{"other":"guardian"}}
        """),
        sessionMeta("""
        "session_id":"session-42","originator":"codex_cli_rs"
        """),
        #"{"type":"session_meta","payload":null}"#,
        "not-json"
    ]

    private static func sessionMeta(_ payload: String) -> String {
        "{\"type\":\"session_meta\",\"payload\":{\(payload)}}"
    }
}
