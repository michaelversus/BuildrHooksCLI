import Foundation

/// The time's meaning is provider-specific and survives private persistence and replay.
public enum UsageTimestamp: Equatable, Sendable {
    case collected(Int64)
    case received(Int64)

    public var milliseconds: Int64 {
        switch self {
        case let .collected(value), let .received(value): value
        }
    }
}

public enum UsageScope: String, Codable, Sendable { case provider }

public struct UsageSnapshot: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var cliVersion: String?
    public let provider: UsageProvider
    public let scope: UsageScope?
    public let revision: UInt64
    public let timestamp: UsageTimestamp
    public let windows: [UsageWindow]
    public var replayRequestID: String?

    public var collectedAt: Int64? {
        guard case let .collected(value) = timestamp else { return nil }
        return value
    }

    public var receivedAt: Int64? {
        guard case let .received(value) = timestamp else { return nil }
        return value
    }

    public init(provider: UsageProvider, revision: UInt64, collectedAt: Int64, windows: [UsageWindow],
                cliVersion: String? = nil) {
        schemaVersion = 1
        self.cliVersion = cliVersion
        self.provider = provider
        scope = nil
        self.revision = revision
        timestamp = .collected(collectedAt)
        self.windows = windows
    }

    public init(revision: UInt64, receivedAt: Int64, windows: [UsageWindow], cliVersion: String? = nil,
                replayRequestID: String? = nil) {
        schemaVersion = 2
        self.cliVersion = cliVersion
        provider = .claude
        scope = .provider
        self.revision = revision
        timestamp = .received(receivedAt)
        self.windows = windows
        self.replayRequestID = replayRequestID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, cliVersion, provider, scope, revision, collectedAt, receivedAt, windows, replayRequestID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        cliVersion = try values.decodeIfPresent(String.self, forKey: .cliVersion)
        provider = try values.decode(UsageProvider.self, forKey: .provider)
        scope = try values.decodeIfPresent(UsageScope.self, forKey: .scope)
        revision = try values.decode(UInt64.self, forKey: .revision)
        windows = try values.decode([UsageWindow].self, forKey: .windows)
        replayRequestID = try values.decodeIfPresent(String.self, forKey: .replayRequestID)
        switch (schemaVersion, provider, scope) {
        case (1, .codex, nil):
            guard !values.contains(.receivedAt), !values.contains(.scope), !values.contains(.replayRequestID) else {
                throw UsageWireError.invalidPayload
            }
            timestamp = try .collected(values.decode(Int64.self, forKey: .collectedAt))
        case (2, .claude, .provider):
            guard !values.contains(.collectedAt) else { throw UsageWireError.invalidPayload }
            timestamp = try .received(values.decode(Int64.self, forKey: .receivedAt))
        default: throw UsageWireError.invalidPayload
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encodeIfPresent(cliVersion, forKey: .cliVersion)
        try values.encode(provider, forKey: .provider)
        try values.encodeIfPresent(scope, forKey: .scope)
        try values.encode(revision, forKey: .revision)
        switch timestamp {
        case let .collected(value): try values.encode(value, forKey: .collectedAt)
        case let .received(value): try values.encode(value, forKey: .receivedAt)
        }
        try values.encode(windows, forKey: .windows)
        try values.encodeIfPresent(replayRequestID, forKey: .replayRequestID)
    }
}

public struct UsageCollectionStatus: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var cliVersion: String?
    public let provider: UsageProvider
    public let scope: UsageScope?
    public let revision: UInt64
    public let observedAt: Int64
    public let status: UsageStatusCode
    public let retryAt: Int64?
    public let latestInvalidationRevision: UInt64
    public let retainedSnapshotRevision: UInt64?
    public let receivedAt: Int64?
    public var replayRequestID: String?

    public init(provider: UsageProvider, revision: UInt64, observedAt: Int64, status: UsageStatusCode,
                retryAt: Int64? = nil, latestInvalidationRevision: UInt64 = 0, cliVersion: String? = nil) {
        schemaVersion = 1
        self.cliVersion = cliVersion
        self.provider = provider
        scope = nil
        self.revision = revision
        self.observedAt = observedAt
        self.status = status
        self.retryAt = retryAt
        self.latestInvalidationRevision = latestInvalidationRevision
        retainedSnapshotRevision = nil
        receivedAt = nil
    }

    public init(revision: UInt64, observedAt: Int64, status: UsageStatusCode,
                latestInvalidationRevision: UInt64 = 0, retainedSnapshotRevision: UInt64?,
                receivedAt: Int64? = nil, cliVersion: String, replayRequestID: String? = nil) {
        schemaVersion = 2
        self.cliVersion = cliVersion
        provider = .claude
        scope = .provider
        self.revision = revision
        self.observedAt = observedAt
        self.status = status
        retryAt = nil
        self.latestInvalidationRevision = latestInvalidationRevision
        self.retainedSnapshotRevision = retainedSnapshotRevision
        self.receivedAt = receivedAt
        self.replayRequestID = replayRequestID
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, cliVersion, provider, scope, revision, observedAt, status, retryAt
        case latestInvalidationRevision, retainedSnapshotRevision, receivedAt, replayRequestID
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        cliVersion = try values.decodeIfPresent(String.self, forKey: .cliVersion)
        provider = try values.decode(UsageProvider.self, forKey: .provider)
        scope = try values.decodeIfPresent(UsageScope.self, forKey: .scope)
        revision = try values.decode(UInt64.self, forKey: .revision)
        observedAt = try values.decode(Int64.self, forKey: .observedAt)
        status = try values.decode(UsageStatusCode.self, forKey: .status)
        retryAt = try values.decodeIfPresent(Int64.self, forKey: .retryAt)
        latestInvalidationRevision = try values.decode(UInt64.self, forKey: .latestInvalidationRevision)
        retainedSnapshotRevision = try values.decodeIfPresent(UInt64.self, forKey: .retainedSnapshotRevision)
        receivedAt = try values.decodeIfPresent(Int64.self, forKey: .receivedAt)
        replayRequestID = try values.decodeIfPresent(String.self, forKey: .replayRequestID)
        switch (schemaVersion, provider, scope) {
        case (1, .codex, nil):
            guard !values.contains(.scope), !values.contains(.receivedAt),
                  !values.contains(.retainedSnapshotRevision), !values.contains(.replayRequestID) else {
                throw UsageWireError.invalidPayload
            }
        case (2, .claude, .provider):
            guard values.contains(.retainedSnapshotRevision), cliVersion != nil else {
                throw UsageWireError.invalidPayload
            }
        default: throw UsageWireError.invalidPayload
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(schemaVersion, forKey: .schemaVersion)
        try values.encodeIfPresent(cliVersion, forKey: .cliVersion)
        try values.encode(provider, forKey: .provider)
        try values.encodeIfPresent(scope, forKey: .scope)
        try values.encode(revision, forKey: .revision)
        try values.encode(observedAt, forKey: .observedAt)
        try values.encode(status, forKey: .status)
        try values.encodeIfPresent(retryAt, forKey: .retryAt)
        try values.encode(latestInvalidationRevision, forKey: .latestInvalidationRevision)
        if provider == .claude {
            try values.encode(retainedSnapshotRevision, forKey: .retainedSnapshotRevision)
        }
        try values.encodeIfPresent(receivedAt, forKey: .receivedAt)
        try values.encodeIfPresent(replayRequestID, forKey: .replayRequestID)
    }
}
