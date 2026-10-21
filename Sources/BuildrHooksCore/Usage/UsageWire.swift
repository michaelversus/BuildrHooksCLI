import Foundation

public enum UsageProvider: String, Codable, Sendable { case codex, claude }
public enum UsageStatusCode: String, Codable, Sendable {
    case pending, ready
    case authenticationRequired = "authentication_required"
    case temporaryFailure = "temporary_failure"
    case throttled
    case usageUnavailable = "usage_unavailable"
}

public struct UsageWindow: Codable, Equatable, Sendable {
    public let limitCode: String
    public let role: String
    public let usedPercent: Double
    public let durationMinutes: Int64?
    public let resetsAt: Int64?
    public init(
        limitCode: String, role: String, usedPercent: Double, durationMinutes: Int64? = nil, resetsAt: Int64? = nil
    ) {
        self.limitCode = limitCode
        self.role = role
        self.usedPercent = usedPercent
        self.durationMinutes = durationMinutes
        self.resetsAt = resetsAt
    }
}

public enum UsageWireError: Error { case invalidPayload }

/// Snapshot and status revision floors are supplied separately by the receiver.
public struct UsageWire: Sendable {
    public static let maximumBytes = 64 * 1024
    public init() {}

    public func encode(_ snapshot: UsageSnapshot, now: Date) throws -> String {
        try validate(snapshot, now: now)
        return try encodeValue(snapshot)
    }

    public func encode(_ status: UsageCollectionStatus, now: Date) throws -> String {
        try validate(status, now: now)
        return try encodeValue(status)
    }

    public func decodeSnapshot(
        _ payload: String, now: Date, after revision: UInt64 = 0, invalidation: UInt64 = 0
    ) throws -> UsageSnapshot {
        let value: UsageSnapshot = try decodeValue(payload)
        try validate(value, now: now)
        guard value.revision > max(revision, invalidation) else { throw UsageWireError.invalidPayload }
        return value
    }

    public func decodeStatus(
        _ payload: String, now: Date, after revision: UInt64 = 0
    ) throws -> UsageCollectionStatus {
        let value: UsageCollectionStatus = try decodeValue(payload)
        try validate(value, now: now)
        guard value.revision > revision else { throw UsageWireError.invalidPayload }
        return value
    }

    private func validate(_ snapshot: UsageSnapshot, now: Date) throws {
        guard snapshot.revision > 0, validVersion(snapshot.cliVersion),
              validObservation(snapshot.timestamp.milliseconds, now: now), !snapshot.windows.isEmpty,
              validReplayID(snapshot.replayRequestID) else {
            throw UsageWireError.invalidPayload
        }
        switch (snapshot.schemaVersion, snapshot.provider, snapshot.scope, snapshot.timestamp) {
        case (1, .codex, nil, .collected):
            guard snapshot.replayRequestID == nil else { throw UsageWireError.invalidPayload }
        case (2, .claude, .provider, .received): break
        default: throw UsageWireError.invalidPayload
        }
        var identities = Set<String>()
        for window in snapshot.windows {
            guard identities.insert(window.limitCode + ":" + window.role).inserted,
                  validCode(window.limitCode), ["primary", "secondary"].contains(window.role),
                  window.usedPercent.isFinite, window.usedPercent >= 0,
                  window.durationMinutes.map({ $0 > 0 }) ?? true,
                  window.resetsAt.map({ $0 >= 0 }) ?? true else { throw UsageWireError.invalidPayload }
            if snapshot.provider == .claude {
                guard window.limitCode == "claude", window.usedPercent <= 100,
                      window.durationMinutes == (window.role == "primary" ? 300 : 10080) else {
                    throw UsageWireError.invalidPayload
                }
            }
        }
    }

    private func validate(_ status: UsageCollectionStatus, now: Date) throws {
        guard status.revision > 0, validVersion(status.cliVersion), validReplayID(status.replayRequestID),
              validObservation(status.observedAt, now: now),
              status.latestInvalidationRevision <= status.revision,
              status.retryAt.map({ $0 >= 0 }) ?? true else { throw UsageWireError.invalidPayload }
        switch (status.schemaVersion, status.provider, status.scope) {
        case (1, .codex, nil):
            guard status.retainedSnapshotRevision == nil, status.receivedAt == nil,
                  status.replayRequestID == nil else { throw UsageWireError.invalidPayload }
        case (2, .claude, .provider):
            guard status.cliVersion != nil,
                  status.receivedAt.map({ validObservation($0, now: now) && $0 <= status.observedAt }) ?? true,
                  status.retainedSnapshotRevision.map({
                      $0 > status.latestInvalidationRevision && $0 <= status.revision
                  }) ?? true,
                  status.status != .ready || (status.retainedSnapshotRevision != nil && status.receivedAt != nil),
                  status.retainedSnapshotRevision != nil || status.receivedAt == nil
                  || status.status == .usageUnavailable,
                  status.status != .usageUnavailable || status.retainedSnapshotRevision == nil else {
                throw UsageWireError.invalidPayload
            }
        default: throw UsageWireError.invalidPayload
        }
    }

    private func validReplayID(_ value: String?) -> Bool {
        value.map(validCode) ?? true
    }

    private func validVersion(_ version: String?) -> Bool {
        guard let version else { return true }
        guard version.utf8.count <= 128 else { return false }
        let number = "(0|[1-9][0-9]*)"
        let prerelease = "(0|[1-9][0-9]*|[0-9]*[A-Za-z-][0-9A-Za-z-]*)"
        let pattern = "^" + number + "\\." + number + "\\." + number
            + "(-" + prerelease + "(\\." + prerelease + ")*)?(\\+[0-9A-Za-z-]+(\\.[0-9A-Za-z-]+)*)?$"
        return version.range(of: pattern, options: .regularExpression) != nil
            && !version.contains("\n") && !version.contains("\r")
    }

    private func validObservation(_ value: Int64, now: Date) -> Bool {
        value >= 0 && Double(value) <= now.timeIntervalSince1970 * 1000 + 120_000
    }

    private func validCode(_ code: String) -> Bool {
        !code.isEmpty && code.utf8.count <= 128 && code.utf8.allSatisfy {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || [45, 46, 95].contains($0)
        }
    }

    private func encodeValue(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        guard data.count <= Self.maximumBytes else { throw UsageWireError.invalidPayload }
        guard let string = String(data: data, encoding: .utf8) else { throw UsageWireError.invalidPayload }
        return string
    }

    private func decodeValue<Value: Decodable>(_ payload: String) throws -> Value {
        let data = Data(payload.utf8)
        guard data.count <= Self.maximumBytes else { throw UsageWireError.invalidPayload }
        return try JSONDecoder().decode(Value.self, from: data)
    }
}
