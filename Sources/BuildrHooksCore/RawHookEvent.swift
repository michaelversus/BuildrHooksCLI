import Foundation

public struct HookGitContext: Codable, Equatable, Sendable {
    public let headSHA: String?
    public let branchName: String?
    public let isDetachedHead: Bool
    public let gitDirectoryPath: String
    public let gitCommonDirectoryPath: String
    public let remoteURL: String?
    public let upstreamBranch: String?
    public let repositoryFingerprint: String?

    public init(
        headSHA: String?,
        branchName: String?,
        isDetachedHead: Bool,
        gitDirectoryPath: String,
        gitCommonDirectoryPath: String,
        remoteURL: String?,
        upstreamBranch: String?,
        repositoryFingerprint: String?
    ) {
        self.headSHA = headSHA
        self.branchName = branchName
        self.isDetachedHead = isDetachedHead
        self.gitDirectoryPath = gitDirectoryPath
        self.gitCommonDirectoryPath = gitCommonDirectoryPath
        self.remoteURL = remoteURL
        self.upstreamBranch = upstreamBranch
        self.repositoryFingerprint = repositoryFingerprint
    }
}

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
    public let turnID: String?
    public let repositoryFingerprint: String?
    public let gitContext: HookGitContext?
    public let rawPayload: String

    public init(
        payloadVersion: Int = 2,
        agentKind: HookAgentKind,
        eventKind: HookEventKind,
        createdAt: Date,
        currentWorkingDirectory: String,
        repositoryRootPath: String,
        sessionID: String?,
        transcriptPath: String?,
        model: String?,
        turnID: String? = nil,
        repositoryFingerprint: String? = nil,
        gitContext: HookGitContext? = nil,
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
        self.turnID = turnID
        self.repositoryFingerprint = repositoryFingerprint
        self.gitContext = gitContext
        self.rawPayload = rawPayload
    }
}
