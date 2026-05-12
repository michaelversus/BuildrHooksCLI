@testable import BuildrHooksCore
import Foundation
import Testing

struct CodexRawHookEventFactoryTests {
    struct SuccessCase: CustomTestStringConvertible {
        let description: String
        let kind: HookEventKind
        let payload: String
        let createdAt: Date
        let currentWorkingDirectory: String
        let repositoryRoot: String
        let expectedSessionID: String
        let expectedTranscriptPath: String?
        let expectedModel: String?
        let expectedTurnID: String?

        var testDescription: String {
            description
        }
    }

    struct InvalidPayloadCase: CustomTestStringConvertible {
        let description: String
        let kind: HookEventKind
        let payload: String

        var testDescription: String {
            description
        }
    }

    @Test(arguments: successCases)
    func makeEventParsesSupportedCodexPayloads(testCase: SuccessCase) throws {
        let gitContext = HookGitContext(
            headSHA: "0123456789abcdef0123456789abcdef01234567",
            branchName: "main",
            isDetachedHead: false,
            gitDirectoryPath: "/tmp/repo/.git",
            gitCommonDirectoryPath: "/tmp/repo/.git",
            remoteURL: "git@github.com:example/project.git",
            upstreamBranch: "origin/main",
            repositoryFingerprint: "fingerprint-123"
        )
        let event = try CodexRawHookEventFactory(
            gitContextReader: HookGitContextReaderStub(gitContext: gitContext)
        ).makeEvent(
            kind: testCase.kind,
            rawPayload: Data(testCase.payload.utf8),
            createdAt: testCase.createdAt,
            currentWorkingDirectory: testCase.currentWorkingDirectory,
            repositoryRoot: testCase.repositoryRoot
        )

        #expect(event.agentKind == .codex)
        #expect(event.eventKind == testCase.kind)
        #expect(event.createdAt == testCase.createdAt)
        #expect(event.currentWorkingDirectory == testCase.currentWorkingDirectory)
        #expect(event.repositoryRootPath == testCase.repositoryRoot)
        #expect(event.sessionID == testCase.expectedSessionID)
        #expect(event.transcriptPath == testCase.expectedTranscriptPath)
        #expect(event.model == testCase.expectedModel)
        #expect(event.payloadVersion == 2)
        #expect(event.turnID == testCase.expectedTurnID)
        #expect(event.repositoryFingerprint == "fingerprint-123")
        #expect(event.gitContext == gitContext)
        #expect(event.rawPayload == testCase.payload)
    }

    @Test
    func makeEventKeepsHookUsableWhenGitContextIsUnavailable() throws {
        let payload = #"{"session_id":"session-42","turn_id":"turn-42"}"#

        let event = try CodexRawHookEventFactory(
            gitContextReader: HookGitContextReaderStub(gitContext: nil)
        ).makeEvent(
            kind: .sessionStart,
            rawPayload: Data(payload.utf8),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            currentWorkingDirectory: "/tmp/worktree",
            repositoryRoot: "/tmp/repo"
        )

        #expect(event.payloadVersion == 2)
        #expect(event.turnID == "turn-42")
        #expect(event.repositoryFingerprint == nil)
        #expect(event.gitContext == nil)
    }

    @Test(arguments: invalidPayloadCases)
    func makeEventRejectsInvalidCodexPayloads(testCase: InvalidPayloadCase) {
        do {
            _ = try CodexRawHookEventFactory().makeEvent(
                kind: testCase.kind,
                rawPayload: Data(testCase.payload.utf8),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                currentWorkingDirectory: "/tmp/worktree",
                repositoryRoot: "/tmp/repo"
            )
            Issue.record("Expected invalid payload error for \(testCase.description).")
        } catch let error as CodexHookRelayError {
            #expect(error == .invalidPayload)
        } catch {
            Issue.record("Unexpected error for \(testCase.description): \(error)")
        }
    }

    static let successCases: [SuccessCase] = [
        SuccessCase(
            description: "session-start decodes transcript path and model",
            kind: .sessionStart,
            payload: """
            {"session_id":"session-start-42","transcript_path":"/tmp/session-start.jsonl",\
            "model":"gpt-5.1","turn_id":"turn-session-start"}
            """,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            currentWorkingDirectory: "/tmp/session-start",
            repositoryRoot: "/tmp/repo-session-start",
            expectedSessionID: "session-start-42",
            expectedTranscriptPath: "/tmp/session-start.jsonl",
            expectedModel: "gpt-5.1",
            expectedTurnID: "turn-session-start"
        ),
        SuccessCase(
            description: "prompt-submit decodes required prompt while preserving nil optionals",
            kind: .promptSubmit,
            payload: """
            {"session_id":"prompt-42","transcript_path":null,"prompt":"ship it",\
            "model":null,"turn_id":"turn-prompt"}
            """,
            createdAt: Date(timeIntervalSince1970: 1_700_000_001),
            currentWorkingDirectory: "/tmp/prompt-submit",
            repositoryRoot: "/tmp/repo-prompt-submit",
            expectedSessionID: "prompt-42",
            expectedTranscriptPath: nil,
            expectedModel: nil,
            expectedTurnID: "turn-prompt"
        ),
        SuccessCase(
            description: "stop decodes optional fields when omitted",
            kind: .stop,
            payload: #"{"session_id":"stop-42"}"#,
            createdAt: Date(timeIntervalSince1970: 1_700_000_002),
            currentWorkingDirectory: "/tmp/stop",
            repositoryRoot: "/tmp/repo-stop",
            expectedSessionID: "stop-42",
            expectedTranscriptPath: nil,
            expectedModel: nil,
            expectedTurnID: nil
        )
    ]

    static let invalidPayloadCases: [InvalidPayloadCase] = [
        InvalidPayloadCase(
            description: "malformed JSON maps dataCorrupted to invalidPayload",
            kind: .sessionStart,
            payload: "not-json"
        ),
        InvalidPayloadCase(
            description: "missing session identifier maps keyNotFound to invalidPayload",
            kind: .sessionStart,
            payload: #"{"transcript_path":"/tmp/missing-session.jsonl","model":"gpt-5"}"#
        ),
        InvalidPayloadCase(
            description: "wrong field type maps typeMismatch to invalidPayload",
            kind: .promptSubmit,
            payload: #"{"session_id":"prompt-42","prompt":"ship it","model":99}"#
        ),
        InvalidPayloadCase(
            description: "null required field maps valueNotFound to invalidPayload",
            kind: .stop,
            payload: #"{"session_id":null}"#
        )
    ]
}

private struct HookGitContextReaderStub: HookGitContextReading {
    let gitContext: HookGitContext?

    func gitContext(repositoryRoot _: String) -> HookGitContext? {
        gitContext
    }
}
