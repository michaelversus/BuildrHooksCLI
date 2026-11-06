import CryptoKit
import Foundation

/// App-owned project authorization. The CLI reads this file and never installs or repairs it.
public struct TrackingConfiguration: Codable, Sendable {
    public let version: Int
    public let scope: BridgeScope
    public let enabled: Bool

    public init(version: Int, scope: BridgeScope, enabled: Bool) {
        self.version = version
        self.scope = scope
        self.enabled = enabled
    }
}

/// Producer-supplied completion evidence from one successful creating Git invocation.
/// It is not a transcript parser or independent authentication of the producer.
public struct TrackingCommitExecution: Codable, Equatable, Sendable {
    public var invocationID: String
    public var session: BridgeSession
    public var repository: BridgeRepository
    public var rootPath: String
    public var argv: [String]
    public var exitCode: Int
    public var headBefore: String?
    public var headAfter: String

    public init(invocationID: String, session: BridgeSession, repository: BridgeRepository,
                rootPath: String, argv: [String], exitCode: Int, headBefore: String?, headAfter: String) {
        self.invocationID = invocationID
        self.session = session
        self.repository = repository
        self.rootPath = rootPath
        self.argv = argv
        self.exitCode = exitCode
        self.headBefore = headBefore
        self.headAfter = headAfter
    }
}

public struct TrackingRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let scope: BridgeScope
    public let receipt: BridgeCommitReceipt
    public let execution: TrackingCommitExecution
    public let recordedAt: Double

    public init(version: Int, scope: BridgeScope, receipt: BridgeCommitReceipt,
                execution: TrackingCommitExecution, recordedAt: Double) {
        self.version = version
        self.scope = scope
        self.receipt = receipt
        self.execution = execution
        self.recordedAt = recordedAt
    }
}

public struct TrackingResult: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        case queued, replay, acknowledged, disabled, missingSetup, incompatibleVersion, invalidInput, failed, busy
    }

    public let version: Int
    public let status: Status
    public let action: String
    public let records: [TrackingRecord]
    public let rewrites: [TrackingRewriteRecord]

    public init(version: Int, status: Status, action: String, records: [TrackingRecord],
                rewrites: [TrackingRewriteRecord] = []) {
        self.version = version
        self.status = status
        self.action = action
        self.records = records
        self.rewrites = rewrites
    }
}

public extension BridgeValidator {
    /// Validates explicit completion evidence; never infer creation from a starting HEAD or text.
    static func validate(_ proof: TrackingCommitExecution, scope: BridgeScope) throws -> BridgeCommitReceipt {
        try validate(scope)
        try requireID(proof.invocationID)
        try validate(proof.session)
        guard proof.repository == scope.repository, proof.rootPath == scope.rootPath,
              proof.exitCode == 0, proof.headBefore != proof.headAfter,
              proof.argv.count >= 2, ["git", "/usr/bin/git"].contains(proof.argv[0]),
              proof.argv[1] == "commit", !proof.argv.contains("--dry-run") else {
            throw BridgeValidationError.invalidPayload
        }
        try requireSHA(proof.headAfter)
        if let before = proof.headBefore {
            try requireSHA(before)
        }
        // Length-delimited JSON avoids delimiter collisions in source/session/invocation identities.
        let identity = [scope.repository.host, scope.repository.owner, scope.repository.name,
                        proof.session.source.rawValue, proof.session.sessionID, proof.invocationID]
        let digest = try SHA256.hash(data: JSONEncoder().encode(identity))
        let recordID = "commit-" + digest.map { String(format: "%02x", $0) }.joined()
        return BridgeCommitReceipt(recordID: recordID, repository: proof.repository,
                                   session: proof.session, commit: proof.headAfter)
    }
}

/// Explicit producer-supplied transformation evidence, with no replacement session attribution.
public struct TrackingRewriteExecution: Codable, Equatable, Sendable {
    public var invocationID: String
    public var repository: BridgeRepository
    public var rootPath: String
    public var kind: BridgeRewriteRecord.Kind
    public var mappings: [BridgeRewritePair]

    public init(invocationID: String, repository: BridgeRepository, rootPath: String,
                kind: BridgeRewriteRecord.Kind, mappings: [BridgeRewritePair]) {
        self.invocationID = invocationID
        self.repository = repository
        self.rootPath = rootPath
        self.kind = kind
        self.mappings = mappings
    }
}

public struct TrackingRewriteRecord: Codable, Equatable, Sendable {
    public let version: Int
    public let scope: BridgeScope
    public let receipt: BridgeRewriteRecord
    public let execution: TrackingRewriteExecution
    public let recordedAt: Double

    public init(version: Int, scope: BridgeScope, receipt: BridgeRewriteRecord,
                execution: TrackingRewriteExecution, recordedAt: Double) {
        self.version = version
        self.scope = scope
        self.receipt = receipt
        self.execution = execution
        self.recordedAt = recordedAt
    }
}

public extension BridgeValidator {
    static func validate(_ proof: TrackingRewriteExecution, scope: BridgeScope) throws -> BridgeRewriteRecord {
        try validate(scope)
        try requireID(proof.invocationID)
        guard proof.repository == scope.repository, proof.rootPath == scope.rootPath else {
            throw BridgeValidationError.scopeMismatch
        }
        let identity = [scope.repository.host, scope.repository.owner, scope.repository.name,
                        scope.projectID, scope.rootPath, proof.invocationID]
        let digest = try SHA256.hash(data: JSONEncoder().encode(identity))
        let recordID = "rewrite-" + digest.map { String(format: "%02x", $0) }.joined()
        let receipt = BridgeRewriteRecord(recordID: recordID, repository: proof.repository,
                                          kind: proof.kind, mappings: proof.mappings)
        try validate(receipt, scope: scope)
        return receipt
    }
}

public extension TrackingResult {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        status = try values.decode(Status.self, forKey: .status)
        action = try values.decode(String.self, forKey: .action)
        records = try values.decode([TrackingRecord].self, forKey: .records)
        rewrites = try values.decodeIfPresent([TrackingRewriteRecord].self, forKey: .rewrites) ?? []
    }
}
