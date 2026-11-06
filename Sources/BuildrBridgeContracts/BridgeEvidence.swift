import Foundation

public struct BridgePullRequest: Codable, Equatable, Sendable {
    public let baseRepository: BridgeRepository
    public let sourceRepository: BridgeRepository
    public let number: Int
    public let head: String
    public let commits: [String]

    public init(
        baseRepository: BridgeRepository,
        sourceRepository: BridgeRepository,
        number: Int,
        head: String,
        commits: [String]
    ) {
        self.baseRepository = baseRepository
        self.sourceRepository = sourceRepository
        self.number = number
        self.head = head
        self.commits = commits
    }
}

public struct BridgeCoverage: Codable, Equatable, Sendable {
    public let state: State
    public let notes: [String]

    public init(state: State, notes: [String]) {
        self.state = state
        self.notes = notes
    }
}

public struct BridgeProvenance: Codable, Equatable, Sendable {
    public let kind: Kind
    public let commit: String?

    public init(kind: Kind, commit: String?) {
        self.kind = kind
        self.commit = commit
    }
}

public struct BridgeCandidate: Codable, Equatable, Sendable {
    public let session: BridgeSession
    public let header: String
    public let parent: BridgeSession?
    public let children: [BridgeSession]
    public let provenance: [BridgeProvenance]
    public let coverage: BridgeCoverage

    public init(
        session: BridgeSession,
        header: String,
        parent: BridgeSession?,
        children: [BridgeSession],
        provenance: [BridgeProvenance],
        coverage: BridgeCoverage
    ) {
        self.session = session
        self.header = header
        self.parent = parent
        self.children = children
        self.provenance = provenance
        self.coverage = coverage
    }
}

public struct BridgeDisclosure: Codable, Equatable, Sendable {
    public let policyRevision: String
    public let includeOriginalPrompts: Bool

    public init(policyRevision: String, includeOriginalPrompts: Bool) {
        self.policyRevision = policyRevision
        self.includeOriginalPrompts = includeOriginalPrompts
    }
}

public struct BridgeSnapshot: Codable, Equatable, Sendable {
    public let snapshotID: String
    public let requestID: String
    public let scope: BridgeScope
    public let target: BridgePullRequest
    public let selection: [BridgeSession]
    public let evidenceRevision: String
    public let disclosure: BridgeDisclosure
    public let capturedAt: Double

    public init(
        snapshotID: String,
        requestID: String,
        scope: BridgeScope,
        target: BridgePullRequest,
        selection: [BridgeSession],
        evidenceRevision: String,
        disclosure: BridgeDisclosure,
        capturedAt: Double
    ) {
        self.snapshotID = snapshotID
        self.requestID = requestID
        self.scope = scope
        self.target = target
        self.selection = selection
        self.evidenceRevision = evidenceRevision
        self.disclosure = disclosure
        self.capturedAt = capturedAt
    }
}

public struct BridgeMetrics: Codable, Equatable, Sendable {
    public let inputTokens: BridgeMetricValue
    public let outputTokens: BridgeMetricValue
    public let cacheReadTokens: BridgeMetricValue
    public let cacheWriteTokens: BridgeMetricValue
    public let workingSeconds: BridgeMetricValue

    public init(
        inputTokens: BridgeMetricValue,
        outputTokens: BridgeMetricValue,
        cacheReadTokens: BridgeMetricValue,
        cacheWriteTokens: BridgeMetricValue,
        workingSeconds: BridgeMetricValue
    ) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.workingSeconds = workingSeconds
    }
}

public struct BridgeEvidenceRecord: Codable, Equatable, Sendable {
    public let evidenceID: String
    public let kind: BridgeActivityKind
    public let text: String
    public let outcome: BridgeOutcome
    public let occurredAt: Double

    public init(
        evidenceID: String,
        kind: BridgeActivityKind,
        text: String,
        outcome: BridgeOutcome,
        occurredAt: Double
    ) {
        self.evidenceID = evidenceID
        self.kind = kind
        self.text = text
        self.outcome = outcome
        self.occurredAt = occurredAt
    }
}

public struct BridgeSessionEvidence: Codable, Equatable, Sendable {
    public let candidate: BridgeCandidate
    public let metrics: BridgeMetrics
    public let coverage: BridgeCoverage
    public let records: [BridgeEvidenceRecord]
    public let modelSettings: [BridgeModelSetting]
    public let skills: [BridgeSkillEvidence]

    public init(
        candidate: BridgeCandidate,
        metrics: BridgeMetrics,
        coverage: BridgeCoverage,
        records: [BridgeEvidenceRecord],
        modelSettings: [BridgeModelSetting],
        skills: [BridgeSkillEvidence]
    ) {
        self.candidate = candidate
        self.metrics = metrics
        self.coverage = coverage
        self.records = records
        self.modelSettings = modelSettings
        self.skills = skills
    }
}

public struct BridgeModelSetting: Codable, Equatable, Sendable {
    public let model: String?
    public let reasoningEffort: String?
    public let occurredAt: Double

    public init(model: String?, reasoningEffort: String?, occurredAt: Double) {
        self.model = model
        self.reasoningEffort = reasoningEffort
        self.occurredAt = occurredAt
    }
}

public struct BridgeSkillEvidence: Codable, Equatable, Sendable {
    public let name: String
    public let provenance: Provenance

    public init(name: String, provenance: Provenance) {
        self.name = name
        self.provenance = provenance
    }
}

public struct BridgeEvidencePacket: Codable, Equatable, Sendable {
    public let snapshot: BridgeSnapshot
    public let sessions: [BridgeSessionEvidence]
    public let rollupMetrics: BridgeMetrics
    public let coverage: BridgeCoverage

    public init(
        snapshot: BridgeSnapshot,
        sessions: [BridgeSessionEvidence],
        rollupMetrics: BridgeMetrics,
        coverage: BridgeCoverage
    ) {
        self.snapshot = snapshot
        self.sessions = sessions
        self.rollupMetrics = rollupMetrics
        self.coverage = coverage
    }
}

public struct BridgeGeneratedSummary: Codable, Equatable, Sendable {
    public let session: BridgeSession
    public let text: String
    public let evidenceIDs: [String]

    public init(session: BridgeSession, text: String, evidenceIDs: [String]) {
        self.session = session
        self.text = text
        self.evidenceIDs = evidenceIDs
    }
}

public struct BridgeGeneratedGroup: Codable, Equatable, Sendable {
    public let session: BridgeSession
    public let text: String
    public let kind: BridgeActivityKind
    public let outcome: BridgeOutcome
    public let evidenceIDs: [String]

    public init(
        session: BridgeSession,
        text: String,
        kind: BridgeActivityKind,
        outcome: BridgeOutcome,
        evidenceIDs: [String]
    ) {
        self.session = session
        self.text = text
        self.kind = kind
        self.outcome = outcome
        self.evidenceIDs = evidenceIDs
    }
}

public struct BridgeGeneratedContent: Codable, Equatable, Sendable {
    public let snapshot: BridgeSnapshot
    public let summaries: [BridgeGeneratedSummary]
    public let groups: [BridgeGeneratedGroup]

    public init(snapshot: BridgeSnapshot, summaries: [BridgeGeneratedSummary], groups: [BridgeGeneratedGroup]) {
        self.snapshot = snapshot
        self.summaries = summaries
        self.groups = groups
    }
}
