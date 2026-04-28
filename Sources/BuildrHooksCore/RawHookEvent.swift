import Foundation

public struct RawHookEvent: Codable, Equatable, Sendable {
    public let payloadVersion: Int
    public let agentKind: HookAgentKind
    public let eventKind: HookEventKind
    public let createdAt: Date
    public let currentWorkingDirectory: String
    public let repositoryRootPath: String
    public let sessionID: String?
    public let transcriptPath: String?
    public let model: String?
    public let rawPayload: String

    public init(
        payloadVersion: Int = 1,
        agentKind: HookAgentKind,
        eventKind: HookEventKind,
        createdAt: Date,
        currentWorkingDirectory: String,
        repositoryRootPath: String,
        sessionID: String?,
        transcriptPath: String?,
        model: String?,
        rawPayload: String
    ) {
        self.payloadVersion = payloadVersion
        self.agentKind = agentKind
        self.eventKind = eventKind
        self.createdAt = createdAt
        self.currentWorkingDirectory = currentWorkingDirectory
        self.repositoryRootPath = repositoryRootPath
        self.sessionID = sessionID
        self.transcriptPath = transcriptPath
        self.model = model
        self.rawPayload = rawPayload
    }
}
