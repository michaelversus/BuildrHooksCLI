import Foundation

public struct ParsedClaudeHookPayload: Equatable, Sendable {
    public let sessionID: String
    public let transcriptPath: String?
    public let prompt: String?
    public let model: String?
}

private struct ClaudeHookInput: Codable {
    let sessionID: String
    let transcriptPath: String?
    let prompt: String?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case prompt
        case model
    }
}

public struct ClaudeHookPayloadParser: Sendable {
    private let decoder = JSONDecoder()

    public init() {}

    public func parse(kind: HookEventKind, data: Data) throws -> ParsedClaudeHookPayload {
        do {
            let input = try decoder.decode(ClaudeHookInput.self, from: data)
            guard kind != .promptSubmit || input.prompt != nil else {
                throw ClaudeHookRelayError.invalidPayload
            }
            return ParsedClaudeHookPayload(
                sessionID: input.sessionID,
                transcriptPath: input.transcriptPath,
                prompt: kind == .promptSubmit ? input.prompt : nil,
                model: input.model
            )
        } catch let error as ClaudeHookRelayError {
            throw error
        } catch {
            throw ClaudeHookRelayError.invalidPayload
        }
    }
}
