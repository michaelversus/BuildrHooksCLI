import Darwin
import Foundation

public struct UsageProviderState: Codable, Sendable {
    public var revision: UInt64 = 0
    public var latestInvalidationRevision: UInt64 = 0
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
        return try JSONDecoder().decode(UsageDurableState.self, from: data)
    }

    public func save(_ state: UsageDurableState) throws {
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
    }
}
