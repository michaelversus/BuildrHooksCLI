import Foundation

public extension BridgeValidator {
    static func validate(_ response: BridgeResponse, for request: BridgeRequest) throws {
        guard response.version == 1 else { throw BridgeValidationError.incompatibleVersion }
        guard response.scope == request.scope else { throw BridgeValidationError.scopeMismatch }
        guard response.requestID == request.requestID else { throw BridgeValidationError.responseMismatch }
        switch response.body {
        case let .error(failure): try validateText(failure.action)
        case let .progress(progress): try validateProgress(progress, request: request)
        case .discovered, .resolved, .prepared, .finalized:
            try validateReportResponse(response.body, request: request)
        default: try validateTrackingResponse(response.body, request: request)
        }
    }
}

extension BridgeValidator {
    static func validateProgress(_ progress: BridgeProgress, request: BridgeRequest) throws {
        guard [.discover, .resolve, .prepare, .finalize].contains(request.body.operation) else {
            throw BridgeValidationError.responseMismatch
        }
        try validateText(progress.message)
    }

    static func validateReportResponse(_ body: BridgeResponseBody, request: BridgeRequest) throws {
        switch body {
        case let .discovered(result):
            guard request.body.operation == .discover else { throw BridgeValidationError.responseMismatch }
            try validateCandidates(result.candidates)
            try validate(result.coverage)
        case let .resolved(result): try validateResolution(result, request: request)
        case let .prepared(packet): try validatePrepared(packet, request: request)
        case let .finalized(report):
            guard case let .finalize(content) = request.body, report.snapshot == content.snapshot else {
                throw BridgeValidationError.staleSnapshot
            }
            try validateText(report.markdown)
        default: throw BridgeValidationError.responseMismatch
        }
    }

    static func validateResolution(_ result: BridgeResolutionResult, request: BridgeRequest) throws {
        guard case let .resolve(resolution) = request.body, result.query == resolution.query else {
            throw BridgeValidationError.responseMismatch
        }
        guard !result.choices.isEmpty else { throw BridgeValidationError.invalidPayload }
        try validateCandidates(result.choices)
        if let source = resolution.source, !result.choices.allSatisfy({ $0.session.source == source }) {
            throw BridgeValidationError.responseMismatch
        }
    }

    static func validateTrackingResponse(_ body: BridgeResponseBody, request: BridgeRequest) throws {
        switch body {
        case let .cancelled(cancellation):
            guard case let .cancel(expected) = request.body, cancellation == expected else {
                throw BridgeValidationError.responseMismatch
            }
        case let .recorded(acknowledgement):
            try validateRecorded(acknowledgement, request: request)
        case let .acknowledged(acknowledgement):
            guard case let .acknowledge(expected) = request.body, acknowledgement == expected else {
                throw BridgeValidationError.responseMismatch
            }
        default: throw BridgeValidationError.responseMismatch
        }
    }

    static func validateRecorded(_ acknowledgement: BridgeAcknowledgement, request: BridgeRequest) throws {
        let expected: String
        switch request.body {
        case let .recordCommit(receipt): expected = receipt.recordID
        case let .recordRewrite(record): expected = record.recordID
        default: throw BridgeValidationError.responseMismatch
        }
        guard acknowledgement.recordIDs == [expected] else { throw BridgeValidationError.responseMismatch }
    }

    static func validateCandidates(_ candidates: [BridgeCandidate]) throws {
        let identities = candidates.map(\.session)
        guard Set(identities).count == identities.count else { throw BridgeValidationError.invalidIdentity }
        try candidates.forEach(validate)
    }

    static func validatePrepared(_ packet: BridgeEvidencePacket, request: BridgeRequest) throws {
        guard case let .prepare(preparation) = request.body else { throw BridgeValidationError.responseMismatch }
        guard packet.snapshot.scope == request.scope else { throw BridgeValidationError.scopeMismatch }
        guard packet.snapshot.requestID == request.requestID,
              packet.snapshot.target == preparation.target,
              packet.snapshot.selection == preparation.selection,
              packet.snapshot.disclosure == preparation.disclosure,
              packet.snapshot.capturedAt >= request.createdAt,
              packet.snapshot.capturedAt <= request.deadline else { throw BridgeValidationError.staleSnapshot }
        try validate(packet)
    }
}
