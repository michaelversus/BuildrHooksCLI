@testable import BuildrHooksCore
import Foundation
import Testing

struct CodexHookPayloadParserTests {
    @Test
    func promptSubmitParserExposesPromptAndMetadata() throws {
        let payload = """
        {"session_id":"session-42","transcript_path":"/tmp/session.jsonl","prompt":"ship it",\
        "model":"gpt-5","turn_id":"turn-42"}
        """

        let parsed = try CodexHookPayloadParser().parse(kind: .promptSubmit, data: Data(payload.utf8))

        #expect(parsed.sessionID == "session-42")
        #expect(parsed.transcriptPath == "/tmp/session.jsonl")
        #expect(parsed.prompt == "ship it")
        #expect(parsed.model == "gpt-5")
        #expect(parsed.turnID == "turn-42")
    }

    @Test
    func malformedPromptSubmitStillMapsToInvalidPayload() {
        do {
            _ = try CodexHookPayloadParser().parse(
                kind: .promptSubmit,
                data: Data(#"{"session_id":"session-42"}"#.utf8)
            )
            Issue.record("Expected invalid payload.")
        } catch let error as CodexHookRelayError {
            #expect(error == .invalidPayload)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test
    func sessionStartAndStopDoNotExposePromptText() throws {
        let parser = CodexHookPayloadParser()

        let sessionStart = try parser.parse(
            kind: .sessionStart,
            data: Data(#"{"session_id":"session-42","turn_id":"turn-1"}"#.utf8)
        )
        let stop = try parser.parse(
            kind: .stop,
            data: Data(#"{"session_id":"session-42","turn_id":"turn-2"}"#.utf8)
        )

        #expect(sessionStart.prompt == nil)
        #expect(stop.prompt == nil)
        #expect(sessionStart.turnID == "turn-1")
        #expect(stop.turnID == "turn-2")
    }
}
