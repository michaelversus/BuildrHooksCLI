@testable import BuildrHooksCore
import Foundation
import Testing

struct ClaudeUsagePersistenceTests {
    @Test func legacyCodexMigrationPreservesAllPrivateAndPublicValuesBesideClaude() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/usage/legacy-codex-state.json")
        let file = store()
        defer { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: file.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contentsOf: fixture).write(to: file.fileURL)
        var durable = try file.load()
        let original = try #require(durable.providers["codex"])
        #expect(original.snapshot?.timestamp == .collected(900_000))
        durable.providers["claude"] = claude()
        try file.save(durable)
        let loaded = try file.load()
        let codex = try #require(loaded.providers["codex"])
        #expect(codex.revision == 9 && codex.latestInvalidationRevision == 3)
        #expect(codex.lastFetchStartedAt == 850_000 && codex.retryNotBefore == 2_000_000)
        #expect(codex.temporaryFailureCount == 2)
        #expect(codex.accountFingerprint == "legacy-private-fingerprint")
        #expect(codex.fingerprintSalt == "legacy-private-salt")
        #expect(codex.snapshot == original.snapshot && codex.status == original.status)
        #expect(loaded.providers["claude"]?.snapshot?.timestamp == .received(900_000))
        #expect(loaded.providers["claude"]?.snapshot?.receivedAt == 900_000)
        let permissions = try FileManager.default.attributesOfItem(atPath: file.fileURL.path)
        #expect((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        // A later provider-only invalidation does not alter the Codex partition.
        durable.providers["claude"] = claude(cleared: true)
        try file.save(durable)
        #expect(try file.load().providers["codex"]?.snapshot == original.snapshot)
        #expect(try file.load().providers["claude"]?.snapshot == nil)
        #expect(try file.load().providers["claude"]?.latestInvalidationRevision == 6)
    }

    @Test func invalidClaudePrivateStateCannotOverwriteCommittedData() throws {
        let file = store()
        defer { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
        var durable = UsageDurableState()
        durable.providers["claude"] = claude()
        try file.save(durable)
        let bytes = try Data(contentsOf: file.fileURL)
        var invalid = claude()
        invalid.accountFingerprint = "forbidden-identity"
        try rejects(invalid, file: file, bytes: bytes)
        invalid = claude()
        invalid.fingerprintSalt = "forbidden-salt"
        try rejects(invalid, file: file, bytes: bytes)
        invalid = claude()
        invalid.snapshot = nil // Authoritative retention must match persisted snapshot.
        try rejects(invalid, file: file, bytes: bytes)
        invalid = claude()
        invalid.latestInvalidationRevision = 5
        try rejects(invalid, file: file, bytes: bytes)
        invalid = claude()
        invalid.snapshot = UsageSnapshot(provider: .claude, revision: 5, collectedAt: 900_000,
                                         windows: [window])
        try rejects(invalid, file: file, bytes: bytes)
        let directoryPermissions = try FileManager.default.attributesOfItem(
            atPath: file.fileURL.deletingLastPathComponent().path
        )
        #expect((directoryPermissions[.posixPermissions] as? NSNumber)?.intValue == 0o700)
    }

    private var window: UsageWindow {
        UsageWindow(limitCode: "claude", role: "primary", usedPercent: 0, durationMinutes: 300)
    }

    private func claude(cleared: Bool = false) -> UsageProviderState {
        var state = UsageProviderState()
        state.revision = cleared ? 7 : 6
        state.latestInvalidationRevision = cleared ? 6 : 0
        state.snapshot = cleared ? nil : UsageSnapshot(revision: 5, receivedAt: 900_000, windows: [window])
        state.status = UsageCollectionStatus(revision: state.revision, observedAt: 950_000,
                                             status: cleared ? .usageUnavailable : .ready,
                                             latestInvalidationRevision: state.latestInvalidationRevision,
                                             retainedSnapshotRevision: state.snapshot?.revision,
                                             receivedAt: state.snapshot?.receivedAt, cliVersion: "1.2.8")
        return state
    }

    private func store() -> UsageFileStateStore {
        UsageFileStateStore(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("contract-\(UUID().uuidString)/state.json"))
    }

    private func rejects(_ state: UsageProviderState, file: UsageFileStateStore, bytes: Data) throws {
        var durable = UsageDurableState()
        durable.providers["claude"] = state
        #expect(throws: (any Error).self) { try file.save(durable) }
        #expect(try Data(contentsOf: file.fileURL) == bytes)
    }
}
