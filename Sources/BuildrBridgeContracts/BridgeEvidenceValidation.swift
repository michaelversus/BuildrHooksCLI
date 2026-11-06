import Foundation

public extension BridgeValidator {
    static func validate(_ snapshot: BridgeSnapshot) throws {
        try requireID(snapshot.snapshotID)
        try requireID(snapshot.requestID)
        try requireID(snapshot.evidenceRevision)
        try requireID(snapshot.disclosure.policyRevision)
        try validate(snapshot.scope)
        try validate(snapshot.target)
        try validateSelection(snapshot.selection)
        guard snapshot.scope.repository == snapshot.target.sourceRepository else {
            throw BridgeValidationError.scopeMismatch
        }
        guard snapshot.capturedAt.isFinite, snapshot.capturedAt >= 0 else {
            throw BridgeValidationError.invalidTime
        }
    }

    static func validate(_ packet: BridgeEvidencePacket) throws {
        try validate(packet.snapshot)
        let sessions = packet.sessions.map(\.candidate.session)
        guard Set(sessions) == Set(packet.snapshot.selection), Set(sessions).count == sessions.count else {
            throw BridgeValidationError.invalidIdentity
        }
        try validate(packet.coverage)
        try validate(packet.rollupMetrics)
        var evidenceIDs = Set<String>()
        var hasUsableEvidence = false
        for session in packet.sessions {
            try validate(session.candidate)
            try validate(session.coverage)
            try validate(session.metrics)
            try validateRecords(session, packet: packet, evidenceIDs: &evidenceIDs)
            if !session.records.isEmpty {
                hasUsableEvidence = true
            }
        }
        guard hasUsableEvidence else { throw BridgeValidationError.invalidPayload }
        if packet.sessions.contains(where: { $0.coverage.state != .complete }),
           packet.coverage.state == .complete {
            throw BridgeValidationError.invalidCoverage
        }
    }

    static func validate(_ generated: BridgeGeneratedContent, against packet: BridgeEvidencePacket) throws {
        try validate(packet)
        guard generated.snapshot == packet.snapshot else { throw BridgeValidationError.staleSnapshot }
        let summarySessions = generated.summaries.map(\.session)
        guard Set(summarySessions) == Set(packet.snapshot.selection),
              summarySessions.count == Set(summarySessions).count else {
            throw BridgeValidationError.invalidIdentity
        }
        for summary in generated.summaries {
            try validateText(summary.text)
            try validateReferences(summary.evidenceIDs, session: summary.session, packet: packet,
                                   allowEmpty: packet.sessions.first { $0.candidate.session == summary.session }?
                                       .coverage.state == .unavailable)
        }
        for group in generated.groups {
            try validateText(group.text)
            let records = try validateReferences(group.evidenceIDs, session: group.session, packet: packet)
            guard records.allSatisfy({ $0.kind == group.kind && $0.outcome == group.outcome }) else {
                throw BridgeValidationError.invalidPayload
            }
            let positions = records.compactMap { record in
                packet.sessions.first { $0.candidate.session == group.session }?.records
                    .firstIndex { $0.evidenceID == record.evidenceID }
            }
            guard positions == positions.sorted() else { throw BridgeValidationError.invalidPayload }
        }
    }
}

extension BridgeValidator {
    static func validate(_ candidate: BridgeCandidate) throws {
        try validate(candidate.session)
        try validateText(candidate.header)
        try validate(candidate.coverage)
        if let parent = candidate.parent {
            try validate(parent)
            guard parent != candidate.session else { throw BridgeValidationError.invalidIdentity }
        }
        guard Set(candidate.children).count == candidate.children.count,
              !candidate.children.contains(candidate.session) else { throw BridgeValidationError.invalidIdentity }
        try candidate.children.forEach(validate)
        for provenance in candidate.provenance {
            switch provenance.kind {
            case .recordedCommit, .rewrite, .legacySuccessfulCommit:
                guard let commit = provenance.commit else { throw BridgeValidationError.invalidIdentity }
                try requireSHA(commit)
            case .manual, .memoryProposal:
                guard provenance.commit == nil else { throw BridgeValidationError.invalidPayload }
            }
        }
    }

    static func validate(_ coverage: BridgeCoverage) throws {
        guard coverage.state == .complete || !coverage.notes.isEmpty else {
            throw BridgeValidationError.invalidCoverage
        }
        try coverage.notes.forEach(validateText)
    }

    static func validate(_ metrics: BridgeMetrics) throws {
        let tokens = [metrics.inputTokens, metrics.outputTokens, metrics.cacheReadTokens, metrics.cacheWriteTokens]
        for token in tokens {
            try validate(token)
            if case let .available(value) = token, value.rounded() != value {
                throw BridgeValidationError.invalidMetric
            }
        }
        try validate(metrics.workingSeconds)
    }

    static func validate(_ metric: BridgeMetricValue) throws {
        switch metric {
        case let .available(value):
            guard value.isFinite, value >= 0 else { throw BridgeValidationError.invalidMetric }
        case let .unavailable(reason): try validateText(reason)
        }
    }

    static func validateText(_ text: String) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 65536 else {
            throw BridgeValidationError.invalidPayload
        }
    }

    static func validateRecords(_ session: BridgeSessionEvidence, packet: BridgeEvidencePacket,
                                evidenceIDs: inout Set<String>) throws {
        guard session.records.map(\.occurredAt) == session.records.map(\.occurredAt).sorted() else {
            throw BridgeValidationError.invalidTime
        }
        for record in session.records {
            try requireID(record.evidenceID)
            try validateText(record.text)
            guard evidenceIDs.insert(record.evidenceID).inserted else { throw BridgeValidationError.invalidIdentity }
            guard record.occurredAt.isFinite, record.occurredAt >= 0,
                  record.occurredAt <= packet.snapshot.capturedAt else { throw BridgeValidationError.invalidTime }
        }
        for setting in session.modelSettings {
            guard setting.occurredAt.isFinite, setting.occurredAt >= 0,
                  setting.occurredAt <= packet.snapshot.capturedAt else { throw BridgeValidationError.invalidTime }
            if let model = setting.model {
                try validateText(model)
            }
            if let effort = setting.reasoningEffort {
                try validateText(effort)
            }
        }
        try session.skills.forEach { try validateText($0.name) }
        if session.coverage.state == .unavailable, !session.records.isEmpty {
            throw BridgeValidationError.invalidCoverage
        }
    }

    @discardableResult
    static func validateReferences(_ ids: [String], session: BridgeSession, packet: BridgeEvidencePacket,
                                   allowEmpty: Bool = false) throws -> [BridgeEvidenceRecord] {
        guard let evidence = packet.sessions.first(where: { $0.candidate.session == session }),
              Set(ids).count == ids.count, allowEmpty || !ids.isEmpty else {
            throw BridgeValidationError.staleReference
        }
        return try ids.map { id in
            guard let record = evidence.records.first(where: { $0.evidenceID == id }) else {
                throw BridgeValidationError.staleReference
            }
            return record
        }
    }
}
