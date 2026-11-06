import Foundation

public enum BridgeSource: String, Codable, Sendable {
    case codex, claude
}

public struct BridgeRepository: Codable, Equatable, Sendable {
    public let host: String
    public let owner: String
    public let name: String

    public init(host: String, owner: String, name: String) {
        self.host = host
        self.owner = owner
        self.name = name
    }
}

public struct BridgeScope: Codable, Equatable, Sendable {
    public let repository: BridgeRepository
    public let projectID: String
    public let rootPath: String

    public init(repository: BridgeRepository, projectID: String, rootPath: String) {
        self.repository = repository
        self.projectID = projectID
        self.rootPath = rootPath
    }
}

public struct BridgeSession: Codable, Equatable, Hashable, Sendable {
    public let source: BridgeSource
    public let sessionID: String

    public init(source: BridgeSource, sessionID: String) {
        self.source = source
        self.sessionID = sessionID
    }
}

public struct BridgeResolution: Codable, Equatable, Sendable {
    public let query: String
    public let source: BridgeSource?

    public init(query: String, source: BridgeSource?) {
        self.query = query
        self.source = source
    }
}

public struct BridgeRequest: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let scope: BridgeScope
    public let createdAt: Double
    public let deadline: Double
    public let body: BridgeRequestBody

    public init(
        version: Int,
        requestID: String,
        scope: BridgeScope,
        createdAt: Double,
        deadline: Double,
        body: BridgeRequestBody
    ) {
        self.version = version
        self.requestID = requestID
        self.scope = scope
        self.createdAt = createdAt
        self.deadline = deadline
        self.body = body
    }
}

public enum BridgeRequestBody: Codable, Equatable, Sendable {
    case discover(BridgePullRequest)
    case resolve(BridgeResolution)
    case prepare(BridgePreparation)
    case finalize(BridgeGeneratedContent)
    case cancel(BridgeCancellation)
    case recordCommit(BridgeCommitReceipt)
    case recordRewrite(BridgeRewriteRecord)
    case acknowledge(BridgeAcknowledgement)
}

public extension BridgeRequestBody {
    var operation: BridgeOperation {
        switch self {
        case .discover: .discover
        case .resolve: .resolve
        case .prepare: .prepare
        case .finalize: .finalize
        case .cancel: .cancel
        case .recordCommit: .recordCommit
        case .recordRewrite: .recordRewrite
        case .acknowledge: .acknowledge
        }
    }
}
