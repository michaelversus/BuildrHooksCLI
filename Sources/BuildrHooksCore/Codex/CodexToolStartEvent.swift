import Foundation

public struct CodexToolStartEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 1

    public let schemaVersion: Int
    public let eventType: String
    public let source: HookAgentKind
    public let sessionID: String
    public let executionSurface: ExecutionSurface?
    public let toolName: String
    public let timestamp: Date
    public let invocationID: String?

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case eventType = "event_type"
        case source
        case sessionID = "session_id"
        case executionSurface = "execution_surface"
        case toolName = "tool_name"
        case timestamp
        case invocationID = "invocation_id"
    }

    public init(
        sessionID: String,
        executionSurface: ExecutionSurface?,
        toolName: String,
        timestamp: Date,
        invocationID: String?
    ) {
        schemaVersion = Self.currentSchemaVersion
        eventType = "tool_start"
        source = .codex
        self.sessionID = sessionID
        self.executionSurface = executionSurface
        self.toolName = toolName
        self.timestamp = timestamp
        self.invocationID = invocationID
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(eventType, forKey: .eventType)
        try container.encode(source, forKey: .source)
        try container.encode(sessionID, forKey: .sessionID)
        try container.encodeIfPresent(executionSurface, forKey: .executionSurface)
        try container.encode(toolName, forKey: .toolName)
        try container.encode(timestamp, forKey: .timestamp)
        try container.encodeIfPresent(invocationID, forKey: .invocationID)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        eventType = try container.decode(String.self, forKey: .eventType)
        source = try container.decode(HookAgentKind.self, forKey: .source)
        sessionID = try container.decode(String.self, forKey: .sessionID)
        executionSurface = try container.decodeIfPresent(ExecutionSurface.self, forKey: .executionSurface)
        toolName = try container.decode(String.self, forKey: .toolName)
        timestamp = try container.decode(Date.self, forKey: .timestamp)
        invocationID = try container.decodeIfPresent(String.self, forKey: .invocationID)
    }
}

private struct CodexToolStartInput: Decodable {
    let sessionID: String
    let transcriptPath: String?
    let toolName: String
    let invocationID: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case transcriptPath = "transcript_path"
        case toolName = "tool_name"
        case invocationID = "tool_use_id"
    }
}

public struct CodexToolStartEventFactory: Sendable {
    private let executionSurfaceResolver: CodexTranscriptExecutionSurfaceResolver

    public init(executionSurfaceResolver: CodexTranscriptExecutionSurfaceResolver = .init()) {
        self.executionSurfaceResolver = executionSurfaceResolver
    }

    public func makeEvent(rawPayload: Data, timestamp: Date) throws -> CodexToolStartEvent {
        let input: CodexToolStartInput
        do {
            input = try JSONDecoder().decode(CodexToolStartInput.self, from: rawPayload)
        } catch {
            throw CodexHookRelayError.invalidPayload
        }

        guard
            !input.sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !input.toolName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw CodexHookRelayError.invalidPayload
        }

        let invocationID = input.invocationID.flatMap { value in
            value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : value
        }
        return CodexToolStartEvent(
            sessionID: input.sessionID,
            executionSurface: executionSurfaceResolver.resolve(
                transcriptPath: input.transcriptPath,
                sessionID: input.sessionID
            ),
            toolName: input.toolName,
            timestamp: timestamp,
            invocationID: invocationID
        )
    }
}
