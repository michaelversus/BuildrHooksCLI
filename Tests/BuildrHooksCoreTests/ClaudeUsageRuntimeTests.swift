@testable import BuildrHooksCore
import Foundation
import Testing

struct ClaudeUsageRuntimeTests {
    @Test func claudeClearIsProviderLocalAndAuthoritativelyUnavailable() throws {
        let fixture = ClaudeRuntimeFixture()
        let result = fixture.runtime().clear(provider: .claude)
        #expect(result.outcome == .cleared && result.localCleared && result.publicationAttempted)
        let state = try #require(fixture.durable.providers["claude"])
        #expect(state.status?.status == .usageUnavailable)
        #expect(state.status?.schemaVersion == 2 && state.status?.retainedSnapshotRevision == nil)
        #expect(state.latestInvalidationRevision > 0 && state.snapshot == nil)
        #expect(fixture.fetches == 0)
    }

    @Test func claudeRecoveryWithoutPriorStateReportsCorrelatedAbsenceWithoutFetching() throws {
        let fixture = ClaudeRuntimeFixture()
        fixture.runtime().recover(providers: [.claude])
        #expect(fixture.messages.count == 1)
        #expect(fixture.fetches == 0)
        let payload = try #require(fixture.messages.first?.1)
        let status = try UsageWire().decodeStatus(payload, now: fixture.date)
        #expect(status.provider == .claude && status.retainedSnapshotRevision == nil)
    }
}

final class ClaudeRuntimeFixture: UsageFetching, UsageStateStoring, UsageNotifying, @unchecked Sendable {
    var durable = UsageDurableState()
    var messages: [(String, String)] = []
    var time: Int64 = 1_000_000_000
    var fetches = 0
    var failSave = false
    var failPost = false
    var date: Date {
        Date(timeIntervalSince1970: Double(time) / 1000)
    }

    func load() -> UsageDurableState {
        durable
    }

    func save(_ state: UsageDurableState) throws {
        if failSave {
            throw UsageWireError.invalidPayload
        }
        durable = state
    }

    func post(name: String, payload: String) throws {
        messages.append((name, payload))
        if failPost {
            throw UsageWireError.invalidPayload
        }
    }

    func fetch(timeout _: TimeInterval) throws -> Data {
        fetches += 1
        throw UsageFetchError.unavailable
    }

    func runtime() -> UsageRuntime {
        UsageRuntime(fetcher: self, store: self, notifier: self, cliVersion: "1.2.8",
                     now: { self.date }, output: { _ in })
    }
}

extension ClaudeUsageRuntimeTests {
    private var primary: UsageWindow {
        UsageWindow(limitCode: "claude", role: "primary", usedPercent: 0, durationMinutes: 300)
    }

    private var secondary: UsageWindow {
        UsageWindow(limitCode: "claude", role: "secondary", usedPercent: 77.125, durationMinutes: 10080)
    }

    @Test func wholeReportsReplaceAndUnchangedReportsGetNewReceipts() throws {
        let fixture = ClaudeRuntimeFixture()
        let runtime = fixture.runtime()
        #expect(runtime.acceptClaude(windows: [primary, secondary], generation: 0).outcome == .refreshed)
        let original = try #require(fixture.durable.providers["claude"]?.snapshot)
        fixture.time += 1000
        #expect(runtime.acceptClaude(windows: [primary], generation: 0).outcome == .refreshed)
        let partial = try #require(fixture.durable.providers["claude"]?.snapshot)
        #expect(partial.windows == [primary] && partial.revision > original.revision)
        #expect(partial.receivedAt == original.receivedAt.map { $0 + 1000 })
        fixture.time += 2000
        #expect(runtime.acceptClaude(windows: [primary], generation: 0).outcome == .refreshed)
        let unchanged = try #require(fixture.durable.providers["claude"]?.snapshot)
        #expect(unchanged.windows == partial.windows && unchanged.revision > partial.revision)
        #expect(unchanged.receivedAt == partial.receivedAt.map { $0 + 2000 })
        #expect(fixture.fetches == 0)
    }

    @Test func malformedRetainsButQuotaFreeInvalidatesAndClearRetiresPendingWork() throws {
        let fixture = ClaudeRuntimeFixture()
        let runtime = fixture.runtime()
        _ = runtime.acceptClaude(windows: [primary], generation: 0)
        let original = try #require(fixture.durable.providers["claude"]?.snapshot)
        fixture.time += 1000
        #expect(runtime.acceptClaude(windows: nil, generation: 0).outcome == .temporaryFailure)
        var state = try #require(fixture.durable.providers["claude"])
        #expect(state.snapshot == original && state.status?.receivedAt == original.receivedAt)
        #expect(state.status?.revision ?? 0 > original.revision && state.latestInvalidationRevision == 0)
        fixture.time += 1000
        #expect(runtime.acceptClaude(windows: [], generation: 0).outcome == .usageUnavailable)
        state = try #require(fixture.durable.providers["claude"])
        #expect(state.snapshot == nil && state.latestInvalidationRevision > original.revision)
        #expect(state.status?.receivedAt == fixture.time && state.status?.retainedSnapshotRevision == nil)
        #expect(runtime.acceptClaude(windows: [primary], generation: 0).outcome == .refreshed)
        let freshGeneration = try runtime.claudeCaptureGeneration()
        _ = runtime.acceptClaude(windows: [primary], generation: freshGeneration)
        let preClear = try runtime.claudeCaptureGeneration()
        #expect(runtime.clear(provider: .claude).localCleared)
        #expect(runtime.acceptClaude(windows: [secondary], generation: preClear).outcome == .invalidated)
        #expect(fixture.durable.providers["claude"]?.snapshot == nil)
        #expect(try runtime.acceptClaude(windows: [secondary], generation: runtime.claudeCaptureGeneration())
            .outcome == .refreshed)
    }

    @Test func persistenceFailureNeverPublishesAndPublicationFailureKeepsCommittedState() throws {
        let fixture = ClaudeRuntimeFixture()
        let runtime = fixture.runtime()
        _ = runtime.acceptClaude(windows: [primary], generation: 0)
        let original = try #require(fixture.durable.providers["claude"]?.snapshot)
        fixture.failSave = true
        fixture.messages = []
        #expect(runtime.acceptClaude(windows: [secondary], generation: 0).outcome == .persistenceFailure)
        #expect(fixture.messages.isEmpty && fixture.durable.providers["claude"]?.snapshot == original)
        fixture.failSave = false
        fixture.failPost = true
        let failedPost = runtime.acceptClaude(windows: [secondary], generation: 0)
        #expect(failedPost.outcome == .publicationFailure && failedPost.publicationAttempted)
        #expect(fixture.durable.providers["claude"]?.snapshot?.windows == [secondary])
        fixture.failPost = false
        fixture.messages = []
        fixture.time += 10000
        let restarted = fixture.runtime()
        restarted.recover(providers: [.claude], replayRequestID: "current")
        let snapshot = try UsageWire().decodeSnapshot(#require(fixture.messages.first?.1), now: fixture.date)
        #expect(snapshot.replayRequestID == "current" && snapshot.windows == [secondary])
        #expect(snapshot.receivedAt == original.receivedAt)
    }

    @Test func restartRecoveryPreservesReceiptAndIndependentCorrelationsWithoutProviderReads() throws {
        let fixture = ClaudeRuntimeFixture()
        _ = fixture.runtime().acceptClaude(windows: [primary], generation: 0)
        let before = try #require(fixture.durable.providers["claude"])
        fixture.time += 1_000_000
        fixture.messages = []
        let restarted = fixture.runtime()
        restarted.recover(providers: [.claude], replayRequestID: "old-attempt")
        restarted.recover(providers: [.claude], replayRequestID: "old-attempt")
        restarted.recover(providers: [.claude], replayRequestID: "current-attempt")
        #expect(fixture.messages.count == 4 && fixture.fetches == 0)
        for index in [0, 2] {
            let snapshot = try UsageWire().decodeSnapshot(fixture.messages[index].1, now: fixture.date)
            let status = try UsageWire().decodeStatus(fixture.messages[index + 1].1, now: fixture.date)
            #expect(snapshot.receivedAt == before.snapshot?.receivedAt)
            #expect(status.observedAt == before.status?.observedAt)
            #expect(status.retainedSnapshotRevision == snapshot.revision)
            #expect(snapshot.replayRequestID == status.replayRequestID)
        }
        #expect(fixture.messages[2].1.contains("current-attempt"))
        #expect(fixture.durable.providers["claude"]?.snapshot == before.snapshot)
        _ = restarted.clear(provider: .claude)
        fixture.messages = []
        restarted.recover(providers: [.claude], replayRequestID: "after-clear")
        #expect(fixture.messages.count == 1)
        let absence = try UsageWire().decodeStatus(#require(fixture.messages.first?.1), now: fixture.date)
        #expect(absence.retainedSnapshotRevision == nil && absence.replayRequestID == "after-clear")
        #expect(absence.receivedAt == nil && absence.latestInvalidationRevision > before.revision)
    }
}

extension ClaudeUsageRuntimeTests {
    @Test func watchAnswersCorrelatedRecoveryWithoutTriggeringAdditionalCodexCollection() {
        let fixture = ClaudeRuntimeFixture()
        _ = fixture.runtime().acceptClaude(windows: [primary], generation: 0)
        fixture.messages = []
        var runtime = fixture.runtime()
        runtime.isCancelled = { fixture.time > 1_000_030_000 }
        runtime.watch(providers: [.codex], triggers: { [.claudeRecoveryRequested("watch-recovery")] }, wait: { _ in
            fixture.time += 30000
        })
        #expect(fixture.fetches == 1)
        let snapshots = fixture.messages.compactMap { try? UsageWire().decodeSnapshot($0.1, now: fixture.date) }
        #expect(snapshots.count == 2 && snapshots.allSatisfy { $0.provider == .claude })
        #expect(snapshots.allSatisfy { $0.replayRequestID == "watch-recovery" })
    }
}

extension ClaudeUsageRuntimeTests {
    @Test func legacyClearFenceIsAbsentAndInvalidFenceCannotCommit() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/usage/legacy-codex-state.json")
        let decoded = try JSONDecoder().decode(UsageDurableState.self, from: Data(contentsOf: source))
        #expect(decoded.providers["codex"]?.latestClearRevision == nil)
        let encoded = try JSONEncoder().encode(decoded)
        let json = try #require(String(bytes: encoded, encoding: .utf8))
        #expect(!json.contains("latestClearRevision"))
        let fixture = ClaudeRuntimeFixture()
        let runtime = fixture.runtime()
        _ = runtime.clear(provider: .claude)
        let store = UsageFileStateStore(fileURL: URL(fileURLWithPath: "/tmp/fence-\(UUID().uuidString)/state.json"))
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        try store.save(fixture.durable)
        #expect(try store.load().providers["claude"]?.latestClearRevision
            == fixture.durable.providers["claude"]?.latestInvalidationRevision)
        fixture.durable.providers["claude"]?.latestClearRevision = 100
        #expect(throws: (any Error).self) { try store.save(fixture.durable) }
    }
}
