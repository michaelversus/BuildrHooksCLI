import Foundation

public enum CodexHookRelayError: Error, Equatable, LocalizedError {
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "Invalid Codex hook payload."
        }
    }
}

private struct CodexSessionStartInput: Codable {
    let sessionID: String
    let transcriptPath: String?
    let model: String?
    let turnID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case model
        case turnID = "turn_id"
    }
}

private struct CodexPromptInput: Codable {
    let sessionID: String
    let transcriptPath: String?
    let prompt: String
    let model: String?
    let turnID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case prompt
        case model
        case turnID = "turn_id"
    }
}

private struct CodexStopInput: Codable {
    let sessionID: String
    let transcriptPath: String?
    let model: String?
    let turnID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case model
        case turnID = "turn_id"
    }
}

public struct CodexRawHookEventFactory {
    private let decoder = JSONDecoder()
    private let gitContextReader: any HookGitContextReading

    public init(gitContextReader: any HookGitContextReading = FileSystemHookGitContextReader()) {
        self.gitContextReader = gitContextReader
    }

    public func makeEvent(
        kind: HookEventKind,
        rawPayload: Data,
        createdAt: Date,
        currentWorkingDirectory: String,
        repositoryRoot: String
    ) throws -> RawHookEvent {
        let rawString = String(bytes: rawPayload, encoding: .utf8) ?? ""
        let parsed = try parse(kind: kind, data: rawPayload)
        let gitContext = gitContextReader.gitContext(repositoryRoot: repositoryRoot)
        return RawHookEvent(
            agentKind: .codex,
            eventKind: kind,
            createdAt: createdAt,
            currentWorkingDirectory: currentWorkingDirectory,
            repositoryRootPath: repositoryRoot,
            sessionID: parsed.sessionID,
            transcriptPath: parsed.transcriptPath,
            model: parsed.model,
            turnID: parsed.turnID,
            repositoryFingerprint: gitContext?.repositoryFingerprint,
            gitContext: gitContext,
            rawPayload: rawString
        )
    }

    private func parse(kind: HookEventKind, data: Data) throws -> ParsedCodexHookPayload {
        do {
            switch kind {
            case .sessionStart:
                let input = try decoder.decode(CodexSessionStartInput.self, from: data)
                return ParsedCodexHookPayload(
                    sessionID: input.sessionID,
                    transcriptPath: input.transcriptPath,
                    model: input.model,
                    turnID: input.turnID
                )
            case .promptSubmit:
                let input = try decoder.decode(CodexPromptInput.self, from: data)
                return ParsedCodexHookPayload(
                    sessionID: input.sessionID,
                    transcriptPath: input.transcriptPath,
                    model: input.model,
                    turnID: input.turnID
                )
            case .stop:
                let input = try decoder.decode(CodexStopInput.self, from: data)
                return ParsedCodexHookPayload(
                    sessionID: input.sessionID,
                    transcriptPath: input.transcriptPath,
                    model: input.model,
                    turnID: input.turnID
                )
            }
        } catch let error as DecodingError {
            throw mapDecodingError(error)
        } catch {
            throw error
        }
    }

    private func mapDecodingError(_ error: DecodingError) -> CodexHookRelayError {
        switch error {
        case .dataCorrupted, .keyNotFound, .typeMismatch, .valueNotFound:
            .invalidPayload
        @unknown default:
            .invalidPayload
        }
    }
}

private struct ParsedCodexHookPayload {
    let sessionID: String
    let transcriptPath: String?
    let model: String?
    let turnID: String?
}
