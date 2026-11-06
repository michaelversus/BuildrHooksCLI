import Foundation

public struct BridgePreparation: Codable, Equatable, Sendable {
    public let target: BridgePullRequest
    public let selection: [BridgeSession]
    public let disclosure: BridgeDisclosure

    public init(target: BridgePullRequest, selection: [BridgeSession], disclosure: BridgeDisclosure) {
        self.target = target
        self.selection = selection
        self.disclosure = disclosure
    }
}

public struct BridgeCancellation: Codable, Equatable, Sendable {
    public let targetRequestID: String

    public init(targetRequestID: String) {
        self.targetRequestID = targetRequestID
    }
}

public struct BridgeCommitReceipt: Codable, Equatable, Sendable {
    public let recordID: String
    public let repository: BridgeRepository
    public let session: BridgeSession
    public let commit: String

    public init(recordID: String, repository: BridgeRepository, session: BridgeSession, commit: String) {
        self.recordID = recordID
        self.repository = repository
        self.session = session
        self.commit = commit
    }
}

public struct BridgeRewritePair: Codable, Equatable, Sendable {
    public let original: String
    public let replacement: String

    public init(original: String, replacement: String) {
        self.original = original
        self.replacement = replacement
    }
}

public struct BridgeRewriteRecord: Codable, Equatable, Sendable {
    public let recordID: String
    public let repository: BridgeRepository
    public let kind: Kind
    public let mappings: [BridgeRewritePair]

    public init(recordID: String, repository: BridgeRepository, kind: Kind, mappings: [BridgeRewritePair]) {
        self.recordID = recordID
        self.repository = repository
        self.kind = kind
        self.mappings = mappings
    }
}

public struct BridgeAcknowledgement: Codable, Equatable, Sendable {
    public let recordIDs: [String]

    public init(recordIDs: [String]) {
        self.recordIDs = recordIDs
    }
}

public struct BridgeProgress: Codable, Equatable, Sendable {
    public let stage: Stage
    public let message: String

    public init(stage: Stage, message: String) {
        self.stage = stage
        self.message = message
    }
}

public struct BridgeFailure: Codable, Equatable, Sendable {
    public let code: Code
    public let action: String

    public init(code: Code, action: String) {
        self.code = code
        self.action = action
    }
}

public struct BridgeDiscoveryResult: Codable, Equatable, Sendable {
    public let candidates: [BridgeCandidate]
    public let coverage: BridgeCoverage

    public init(candidates: [BridgeCandidate], coverage: BridgeCoverage) {
        self.candidates = candidates
        self.coverage = coverage
    }
}

public struct BridgeResolutionResult: Codable, Equatable, Sendable {
    public let query: String
    public let choices: [BridgeCandidate]

    public init(query: String, choices: [BridgeCandidate]) {
        self.query = query
        self.choices = choices
    }
}

public struct BridgeFinalizedReport: Codable, Equatable, Sendable {
    public let snapshot: BridgeSnapshot
    public let markdown: String

    public init(snapshot: BridgeSnapshot, markdown: String) {
        self.snapshot = snapshot
        self.markdown = markdown
    }
}

public struct BridgeResponse: Codable, Equatable, Sendable {
    public let version: Int
    public let requestID: String
    public let scope: BridgeScope
    public let body: BridgeResponseBody

    public init(version: Int, requestID: String, scope: BridgeScope, body: BridgeResponseBody) {
        self.version = version
        self.requestID = requestID
        self.scope = scope
        self.body = body
    }
}

public extension BridgeCoverage {
    enum State: String, Codable, Sendable {
        case complete, partial, unavailable
    }
}

public extension BridgeProvenance {
    enum Kind: String, Codable, Sendable {
        case recordedCommit, rewrite, legacySuccessfulCommit, manual, memoryProposal
    }
}

public extension BridgeSkillEvidence {
    enum Provenance: String, Codable, Sendable {
        case explicit, inferred, pending
    }
}

public extension BridgeRewriteRecord {
    enum Kind: String, Codable, Sendable {
        case amend, rebase, explicit
    }
}

public extension BridgeProgress {
    enum Stage: String, Codable, Sendable {
        case pending, loading, collecting, preparing, awaitingGeneratedContent, finalizing
    }
}

public extension BridgeFailure {
    enum Code: String, Codable, Sendable {
        case cancelled, busy, timeout, incompatibleVersion, unsupported
        case missingSetup, missingAccess, unresolved, ambiguous, invalidInput, unusableEvidence
        case appUnavailable, launchFailed, staleSnapshot, failed
    }
}

public enum BridgeActivityKind: String, Codable, Sendable {
    case request, read, edit, validation, commit, other
}

public enum BridgeOutcome: String, Codable, Sendable {
    case success, failure, unknown
}

public enum BridgeMetricValue: Codable, Equatable, Sendable {
    case available(Double)
    case unavailable(String)
}

public enum BridgeResponseBody: Codable, Equatable, Sendable {
    case progress(BridgeProgress)
    case discovered(BridgeDiscoveryResult)
    case resolved(BridgeResolutionResult)
    case prepared(BridgeEvidencePacket)
    case finalized(BridgeFinalizedReport)
    case cancelled(BridgeCancellation)
    case recorded(BridgeAcknowledgement)
    case acknowledged(BridgeAcknowledgement)
    case error(BridgeFailure)
}
