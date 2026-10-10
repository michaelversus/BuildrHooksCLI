import Foundation

public enum UsageProvider: String, Codable, Sendable { case codex }
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

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let provider: UsageProvider
    public let revision: UInt64
    public let collectedAt: Int64
    public let windows: [UsageWindow]
    public init(provider: UsageProvider, revision: UInt64, collectedAt: Int64, windows: [UsageWindow]) {
        self.provider = provider
        self.revision = revision
        self.collectedAt = collectedAt
        self.windows = windows
    }
}

public struct UsageCollectionStatus: Codable, Equatable, Sendable {
    public var schemaVersion = 1
    public let provider: UsageProvider
    public let revision: UInt64
    public let observedAt: Int64
    public let status: UsageStatusCode
    public let retryAt: Int64?
    public let latestInvalidationRevision: UInt64
    public init(provider: UsageProvider, revision: UInt64, observedAt: Int64, status: UsageStatusCode,
                retryAt: Int64? = nil, latestInvalidationRevision: UInt64 = 0) {
        self.provider = provider
        self.revision = revision
        self.observedAt = observedAt
        self.status = status
        self.retryAt = retryAt
        self.latestInvalidationRevision = latestInvalidationRevision
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
        guard snapshot.schemaVersion == 1, snapshot.revision > 0,
              validObservation(snapshot.collectedAt, now: now), !snapshot.windows.isEmpty else {
            throw UsageWireError.invalidPayload
        }
        var identities = Set<String>()
        for window in snapshot.windows {
            guard identities.insert(window.limitCode + ":" + window.role).inserted,
                  validCode(window.limitCode), ["primary", "secondary"].contains(window.role),
                  window.usedPercent.isFinite, window.usedPercent >= 0,
                  window.durationMinutes.map({ $0 > 0 }) ?? true,
                  window.resetsAt.map({ $0 >= 0 }) ?? true else { throw UsageWireError.invalidPayload }
        }
    }

    private func validate(_ status: UsageCollectionStatus, now: Date) throws {
        guard status.schemaVersion == 1, status.revision > 0,
              validObservation(status.observedAt, now: now),
              status.latestInvalidationRevision <= status.revision,
              status.retryAt.map({ $0 >= 0 }) ?? true else { throw UsageWireError.invalidPayload }
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
