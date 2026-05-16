import Foundation

public struct ParsedCodexHookPayload: Equatable, Sendable {
    public let sessionID: String
    public let transcriptPath: String?
    public let prompt: String?
    public let model: String?
    public let turnID: String?
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

public struct CodexHookPayloadParser: Sendable {
    private let decoder = JSONDecoder()

    public init() {}

    public func parse(kind: HookEventKind, data: Data) throws -> ParsedCodexHookPayload {
        do {
            switch kind {
            case .sessionStart:
                let input = try decoder.decode(CodexSessionStartInput.self, from: data)
                return ParsedCodexHookPayload(
                    sessionID: input.sessionID,
                    transcriptPath: input.transcriptPath,
                    prompt: nil,
                    model: input.model,
                    turnID: input.turnID
                )
            case .promptSubmit:
                let input = try decoder.decode(CodexPromptInput.self, from: data)
                return ParsedCodexHookPayload(
                    sessionID: input.sessionID,
                    transcriptPath: input.transcriptPath,
                    prompt: input.prompt,
                    model: input.model,
                    turnID: input.turnID
                )
            case .stop:
                let input = try decoder.decode(CodexStopInput.self, from: data)
                return ParsedCodexHookPayload(
                    sessionID: input.sessionID,
                    transcriptPath: input.transcriptPath,
                    prompt: nil,
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
