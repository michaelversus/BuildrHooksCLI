@testable import BuildrHooksCore
import Foundation
import Testing

struct CodexToolStartEventTests {
    @Test
    func capabilitiesAdvertiseCodexToolStartSupportWithoutChangingSchemaVersion() {
        #expect(BuildrHooksCapabilities.current.version == 1)
        #expect(BuildrHooksCapabilities.current.toolStartEvents == [.codex])
    }

    @Test
    func factoryPreservesCodexIdentityAndToolMetadataWithoutContent() throws {
        let payload = #"""
        {"session_id":"session-42","transcript_path":"/tmp/session.jsonl",
         "tool_name":"Bash","tool_use_id":"call-42",
         "tool_input":{"command":"PRIVATE_COMMAND_SENTINEL"},
         "tool_response":"PRIVATE_OUTPUT_SENTINEL"}
        """#
        let event = try CodexToolStartEventFactory(
            executionSurfaceResolver: CodexTranscriptExecutionSurfaceResolver(
                readFile: { _ in Data(Self.cliTranscript.utf8) }
            )
        ).makeEvent(rawPayload: Data(payload.utf8), timestamp: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(event.schemaVersion == 1)
        #expect(event.eventType == "tool_start")
        #expect(event.source == .codex)
        #expect(event.sessionID == "session-42")
        #expect(event.toolName == "Bash")
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(event.invocationID == "call-42")
        #expect(
            event.executionSurface == ExecutionSurface(
                kind: .terminal,
                instanceID: "codex-session:session-42"
            )
        )

        let data = try JSONEncoder().encode(event)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["tool_input"] == nil)
        #expect(json["tool_response"] == nil)
        #expect(json["invocation_id"] as? String == "call-42")
        let encoded = try #require(String(bytes: data, encoding: .utf8))
        #expect(!encoded.contains("PRIVATE_COMMAND_SENTINEL"))
        #expect(!encoded.contains("PRIVATE_OUTPUT_SENTINEL"))
    }

    @Test
    func factoryOmitsInvocationIDAndUnverifiedSurface() throws {
        let payload = #"""
        {"session_id":"session-42","tool_name":"mcp__filesystem__read_file",
         "tool_input":{"path":"PRIVATE_PATH_SENTINEL"}}
        """#
        let event = try CodexToolStartEventFactory(
            executionSurfaceResolver: CodexTranscriptExecutionSurfaceResolver(readFile: { _ in nil })
        ).makeEvent(rawPayload: Data(payload.utf8), timestamp: Date(timeIntervalSince1970: 1_700_000_001))

        let data = try JSONEncoder().encode(event)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["invocation_id"] == nil)
        #expect(json["execution_surface"] == nil)
        let encoded = try #require(String(bytes: data, encoding: .utf8))
        #expect(!encoded.contains("PRIVATE_PATH_SENTINEL"))
    }

    @Test(arguments: [
        "not-json",
        #"{"session_id":"session-42"}"#,
        #"{"session_id":" ","tool_name":"Bash"}"#,
        #"{"session_id":"session-42","tool_name":" "}"#
    ])
    func factoryRejectsInvalidPayloads(_ payload: String) {
        do {
            _ = try CodexToolStartEventFactory().makeEvent(
                rawPayload: Data(payload.utf8),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            )
            Issue.record("Expected invalid Codex tool-start payload.")
        } catch let error as CodexHookRelayError {
            #expect(error == .invalidPayload)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    private static let cliTranscript = #"""
    {"type":"session_meta","payload":{"session_id":"session-42","originator":"codex_cli_rs","source":"cli"}}
    """#
}
