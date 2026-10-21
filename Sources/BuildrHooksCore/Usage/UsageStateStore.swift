import Darwin
import Foundation

public struct UsageProviderState: Codable, Sendable {
    public var revision: UInt64 = 0
    public var latestInvalidationRevision: UInt64 = 0
    public var lastFetchStartedAt: Int64?
    public var retryNotBefore: Int64?
    public var temporaryFailureCount: Int?
    public var accountFingerprint: String?
    public var fingerprintSalt: String?
    public var snapshot: UsageSnapshot?
    public var status: UsageCollectionStatus?
    public init() {}
}

public struct UsageDurableState: Codable, Sendable {
    public var providers: [String: UsageProviderState] = [:]
    public init() {}
}

public protocol UsageStateStoring: Sendable {
    func load() throws -> UsageDurableState
    func save(_ state: UsageDurableState) throws
}

public struct UsageFileStateStore: UsageStateStoring {
    public let fileURL: URL
    public init(fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/buildr-artifacts/account-usage.json")) {
        self.fileURL = fileURL
    }

    public func load() throws -> UsageDurableState {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return .init() }
        let data = try Data(contentsOf: fileURL)
        guard data.count <= 1024 * 1024 else { throw UsageWireError.invalidPayload }
        let state = try JSONDecoder().decode(UsageDurableState.self, from: data)
        try validate(state)
        return state
    }

    public func save(_ state: UsageDurableState) throws {
        try validate(state)
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(state)
        guard data.count <= 1024 * 1024 else { throw UsageWireError.invalidPayload }
        var template = Array(directory.appendingPathComponent(".usage-XXXXXX").path.utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw UsageWireError.invalidPayload }
        guard let temporaryPath = String(
            bytes: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, encoding: .utf8
        ) else { throw UsageWireError.invalidPayload }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); unlink(temporaryPath) }
        guard fchmod(descriptor, 0o600) == 0 else { throw UsageWireError.invalidPayload }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temporaryPath, fileURL.path) == 0 else { throw UsageWireError.invalidPayload }
        let directoryDescriptor = open(directory.path, O_RDONLY | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw UsageWireError.invalidPayload }
        defer { Darwin.close(directoryDescriptor) }
        guard fsync(directoryDescriptor) == 0 else { throw UsageWireError.invalidPayload }
    }

    private func validate(_ durable: UsageDurableState) throws {
        for (key, state) in durable.providers {
            guard let provider = UsageProvider(rawValue: key) else { throw UsageWireError.invalidPayload }
            if provider == .claude {
                // Persistence is independent of a receiver's current clock. Wire receipt
                // checks the two-minute future bound with the injected publication clock.
                let upperBound = Date(timeIntervalSince1970: Double(Int64.max) / 1000)
                if let snapshot = state.snapshot {
                    _ = try UsageWire().encode(snapshot, now: upperBound)
                }
                if let status = state.status {
                    _ = try UsageWire().encode(status, now: upperBound)
                }
                guard state.accountFingerprint == nil, state.fingerprintSalt == nil,
                      state.status?.retainedSnapshotRevision == state.snapshot?.revision,
                      state.snapshot.map({ snapshot in
                          state.status?.receivedAt == nil || state.status?.receivedAt == snapshot.receivedAt
                      }) ?? true else {
                    throw UsageWireError.invalidPayload
                }
            }
            guard state.latestInvalidationRevision <= state.revision,
                  state.lastFetchStartedAt.map({ $0 >= 0 && $0 <= Int64.max - 30000 }) ?? true,
                  state.retryNotBefore.map({ $0 >= 0 }) ?? true,
                  state.temporaryFailureCount.map({ (0 ... 20).contains($0) }) ?? true,
                  state.snapshot.map({ $0.provider.rawValue == key && $0.revision <= state.revision
                          && $0.revision > state.latestInvalidationRevision }) ?? true,
                  state.status.map({ $0.provider.rawValue == key && $0.revision <= state.revision
                          && $0.latestInvalidationRevision == state.latestInvalidationRevision }) ?? true else {
                throw UsageWireError.invalidPayload
            }
        }
    }
}
