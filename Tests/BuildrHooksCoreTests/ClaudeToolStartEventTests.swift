@testable import BuildrHooksCore
import Foundation
import Testing

struct ClaudeToolStartEventTests {
    @Test
    func capabilitiesAdvertiseClaudeToolStartSupportWithoutChangingSchemaVersion() {
        #expect(BuildrHooksCapabilities.current.version == 1)
        #expect(BuildrHooksCapabilities.current.toolStartEvents == [.codex, .claude])
    }

    @Test
    func factoryPreservesClaudeIdentityInvocationAndSubagentWithoutContent() throws {
        let payload = #"""
        {"session_id":"session-42","transcript_path":"/tmp/session.jsonl",
         "tool_name":"Bash","tool_use_id":"toolu_42","agent_id":"agent-42",
         "tool_input":{"command":"PRIVATE_COMMAND_SENTINEL"}}
        """#
        let event = try ClaudeToolStartEventFactory(
            executionSurfaceResolver: ClaudeTranscriptExecutionSurfaceResolver(
                readFile: { _ in Data(#"{"sessionId":"session-42","entrypoint":"claude-desktop"}"#.utf8) }
            )
        ).makeEvent(rawPayload: Data(payload.utf8), timestamp: Date(timeIntervalSince1970: 1_700_000_000))

        #expect(event.schemaVersion == 1)
        #expect(event.eventType == "tool_start")
        #expect(event.source == .claude)
        #expect(event.sessionID == "session-42")
        #expect(event.toolName == "Bash")
        #expect(event.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
        #expect(event.invocationID == "toolu_42")
        #expect(event.subagentID == "agent-42")
        #expect(
            event.executionSurface == ExecutionSurface(
                kind: .desktop,
                instanceID: "claude-session:session-42"
            )
        )

        let data = try JSONEncoder().encode(event)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["source"] as? String == "claude")
        #expect(json["tool_input"] == nil)
        #expect(json["invocation_id"] as? String == "toolu_42")
        #expect(json["subagent_id"] as? String == "agent-42")
        let encoded = try #require(String(bytes: data, encoding: .utf8))
        #expect(!encoded.contains("PRIVATE_COMMAND_SENTINEL"))
    }

    @Test
    func factoryOmitsOptionalIDsAndUnverifiedSurface() throws {
        let payload = #"""
        {"session_id":"session-42","tool_name":"mcp__store__read","tool_input":{"key":"PRIVATE_KEY_SENTINEL"}}
        """#
        let event = try ClaudeToolStartEventFactory(
            executionSurfaceResolver: ClaudeTranscriptExecutionSurfaceResolver(readFile: { _ in nil })
        ).makeEvent(rawPayload: Data(payload.utf8), timestamp: Date(timeIntervalSince1970: 1_700_000_001))

        let data = try JSONEncoder().encode(event)
        let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["invocation_id"] == nil)
        #expect(json["subagent_id"] == nil)
        #expect(json["execution_surface"] == nil)
        let encoded = try #require(String(bytes: data, encoding: .utf8))
        #expect(!encoded.contains("PRIVATE_KEY_SENTINEL"))
    }

    @Test(arguments: [
        "not-json",
        #"{"session_id":"session-42"}"#,
        #"{"session_id":" ","tool_name":"Bash"}"#,
        #"{"session_id":"session-42","tool_name":" "}"#
    ])
    func factoryRejectsInvalidPayloads(_ payload: String) {
        #expect(throws: ClaudeHookRelayError.invalidPayload) {
            try ClaudeToolStartEventFactory().makeEvent(
                rawPayload: Data(payload.utf8),
                timestamp: Date(timeIntervalSince1970: 1_700_000_000)
            )
        }
    }
}
