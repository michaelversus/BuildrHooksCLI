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

    public init(version: Int, status: Status, action: String, records: [TrackingRecord]) {
        self.version = version
        self.status = status
        self.action = action
        self.records = records
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
