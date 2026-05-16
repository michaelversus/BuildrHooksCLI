import Foundation

public enum PromptGateExitCode: Int32, Equatable, Sendable {
    case allow = 0
    case denied = 10
    case busy = 11
    case timeout = 12
    case unavailable = 13
    case invalidConfiguration = 14
    case promptTooLarge = 15
    case protocolError = 16
}

public struct PromptGateExit: Error, Equatable, LocalizedError, Sendable {
    public let code: PromptGateExitCode
    public let message: String

    public init(code: PromptGateExitCode, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? {
        message
    }
}

public struct PromptGateMarker: Codable, Equatable, Sendable {
    public let version: Int
    public let enabled: Bool
    public let projectID: String?
    public let repoPath: String?
    public let setupTimestamp: String?

    enum CodingKeys: String, CodingKey {
        case version
        case enabled
        case projectID = "project_id"
        case repoPath = "repo_path"
        case setupTimestamp = "setup_at"
    }
}

public struct PromptGateRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let createdAt: Date
    public let deadlineAt: Date
    public let source: String
    public let repoPath: String
    public let projectID: String?
    public let sessionID: String?
    public let transcriptPath: String?
    public let model: String?
    public let originalPrompt: String
    public let evaluationPrompt: String
    public let promptCharacterCount: Int
    public let promptCharacterLimit: Int

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case createdAt = "created_at"
        case deadlineAt = "deadline_at"
        case source
        case repoPath = "repo_path"
        case projectID = "project_id"
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case model
        case originalPrompt = "original_prompt"
        case evaluationPrompt = "evaluation_prompt"
        case promptCharacterCount = "prompt_character_count"
        case promptCharacterLimit = "prompt_character_limit"
    }
}

public struct PromptGateResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let decision: Decision
    public let reason: String?
    public let suggestedPrompt: String?

    public enum Decision: String, Codable, Sendable {
        case allow
        case deny
    }

    enum CodingKeys: String, CodingKey {
        case version
        case requestID = "request_id"
        case decision
        case reason
        case suggestedPrompt = "suggested_prompt"
    }
}
