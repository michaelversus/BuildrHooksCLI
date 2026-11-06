import Foundation

public enum BridgeValidationError: String, Error, Codable, Sendable {
    case incompatibleVersion, scopeMismatch, invalidIdentity, invalidTime
    case invalidPayload, staleSnapshot, staleReference, responseMismatch, invalidMetric, invalidCoverage
}

public enum BridgeValidator {
    public static func validate(_ request: BridgeRequest, expectedScope: BridgeScope,
                                preparedPacket: BridgeEvidencePacket? = nil) throws {
        guard request.version == 1 else { throw BridgeValidationError.incompatibleVersion }
        guard request.scope == expectedScope else { throw BridgeValidationError.scopeMismatch }
        try validate(request.scope)
        try requireID(request.requestID)
        guard request.createdAt.isFinite, request.deadline.isFinite,
              request.createdAt >= 0, request.deadline > request.createdAt else {
            throw BridgeValidationError.invalidTime
        }
        try validateBody(request)
        if case let .finalize(content) = request.body {
            guard let preparedPacket else { throw BridgeValidationError.staleSnapshot }
            try validate(content, against: preparedPacket)
        }
    }

    public static func validate(_ scope: BridgeScope) throws {
        try validate(scope.repository)
        try requireID(scope.projectID)
        guard scope.rootPath.hasPrefix("/"),
              URL(fileURLWithPath: scope.rootPath).standardized.path == scope.rootPath else {
            throw BridgeValidationError.invalidIdentity
        }
    }

    public static func validate(_ repository: BridgeRepository) throws {
        let parts = [repository.host, repository.owner, repository.name]
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789-._")
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".."
                && $0.rangeOfCharacter(from: allowed.inverted) == nil }),
            !repository.name.hasSuffix(".git") else {
            throw BridgeValidationError.invalidIdentity
        }
    }

    public static func validate(_ target: BridgePullRequest) throws {
        try validate(target.baseRepository)
        try validate(target.sourceRepository)
        guard target.number > 0, !target.commits.isEmpty,
              Set(target.commits).count == target.commits.count, target.commits.contains(target.head) else {
            throw BridgeValidationError.invalidIdentity
        }
        try requireSHA(target.head)
        try target.commits.forEach(requireSHA)
    }

    static func requireID(_ value: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.count <= 1024, value.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw BridgeValidationError.invalidIdentity
        }
    }

    static func requireSHA(_ value: String) throws {
        guard [40, 64].contains(value.count),
              value.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789abcdef").inverted) == nil else {
            throw BridgeValidationError.invalidIdentity
        }
    }

    static func validate(_ session: BridgeSession) throws {
        try requireID(session.sessionID)
    }

    static func validateSelection(_ selection: [BridgeSession]) throws {
        guard !selection.isEmpty, Set(selection).count == selection.count else {
            throw BridgeValidationError.invalidIdentity
        }
        try selection.forEach(validate)
    }

    static func validateBody(_ request: BridgeRequest) throws {
        switch request.body {
        case let .discover(target): try validate(target)
        case let .resolve(resolution): try requireID(resolution.query)
        case let .prepare(preparation):
            try validate(preparation.target)
            try validateSelection(preparation.selection)
            try requireID(preparation.disclosure.policyRevision)
        case let .finalize(content):
            try validateSnapshotScope(content.snapshot, scope: request.scope)
        case let .cancel(cancellation):
            try validateCancellation(cancellation, requestID: request.requestID)
        case let .recordCommit(receipt): try validate(receipt, scope: request.scope)
        case let .recordRewrite(record): try validate(record, scope: request.scope)
        case let .acknowledge(acknowledgement): try validate(acknowledgement)
        }
        if let target = request.target, target.sourceRepository != request.scope.repository {
            throw BridgeValidationError.scopeMismatch
        }
    }

    static func validateSnapshotScope(_ snapshot: BridgeSnapshot, scope: BridgeScope) throws {
        try validate(snapshot)
        guard snapshot.scope == scope else { throw BridgeValidationError.scopeMismatch }
    }

    static func validateCancellation(_ cancellation: BridgeCancellation, requestID: String) throws {
        try requireID(cancellation.targetRequestID)
        guard cancellation.targetRequestID != requestID else { throw BridgeValidationError.invalidIdentity }
    }

    static func validate(_ receipt: BridgeCommitReceipt, scope: BridgeScope) throws {
        try requireID(receipt.recordID)
        guard receipt.repository == scope.repository else { throw BridgeValidationError.scopeMismatch }
        try validate(receipt.session)
        try requireSHA(receipt.commit)
    }

    static func validate(_ record: BridgeRewriteRecord, scope: BridgeScope) throws {
        try requireID(record.recordID)
        guard record.repository == scope.repository else { throw BridgeValidationError.scopeMismatch }
        guard !record.mappings.isEmpty, Set(record.mappings.map(\.original)).count == record.mappings.count else {
            throw BridgeValidationError.invalidPayload
        }
        for mapping in record.mappings {
            try requireSHA(mapping.original)
            try requireSHA(mapping.replacement)
            guard mapping.original != mapping.replacement,
                  mapping.original.count == mapping.replacement.count,
                  mapping.original.contains(where: { $0 != "0" }),
                  mapping.replacement.contains(where: { $0 != "0" }) else {
                throw BridgeValidationError.invalidPayload
            }
        }
    }

    static func validate(_ acknowledgement: BridgeAcknowledgement) throws {
        guard !acknowledgement.recordIDs.isEmpty,
              Set(acknowledgement.recordIDs).count == acknowledgement.recordIDs.count else {
            throw BridgeValidationError.invalidIdentity
        }
        try acknowledgement.recordIDs.forEach(requireID)
    }
}

public extension BridgeRequest {
    var target: BridgePullRequest? {
        switch body {
        case let .discover(target): target
        case let .prepare(preparation): preparation.target
        case let .finalize(content): content.snapshot.target
        default: nil
        }
    }
}
