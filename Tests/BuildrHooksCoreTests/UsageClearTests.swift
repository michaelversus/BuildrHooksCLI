@testable import BuildrHooksCore
import Foundation
import Testing

private final class ClearFixture: UsageFetching, UsageStateStoring, UsageNotifying, @unchecked Sendable {
    var durable = UsageDurableState()
    var time: Int64 = 1_000_000_000
    var messages: [(String, String)] = []
    var output: [String] = []
    var failSave = false
    var failPost = false
    var onFetch: (() -> Void)?
    var fetchCount = 0
    var identityReadCount = 0
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
        // The marker is already committed when publication begins.
        if let status = try? UsageWire().decodeStatus(payload, now: Date(timeIntervalSince1970: Double(time) / 1000)) {
            #expect(status.latestInvalidationRevision
                == durable.providers[status.provider.rawValue]?.latestInvalidationRevision)
        }
        messages.append((name, payload))
        if failPost {
            throw UsageWireError.invalidPayload
        }
    }

    func currentAccountIdentity(timeout _: TimeInterval) -> String? {
        identityReadCount += 1
        return nil
    }

    func fetch(timeout _: TimeInterval) -> Data {
        fetchCount += 1
        onFetch?()
        return Data(#"{"accountId":"private-account","rateLimits":{"primary":{"usedPercent":12}}}"#.utf8)
    }

    func runtime() -> UsageRuntime {
        UsageRuntime(fetcher: self, store: self, notifier: self,
                     now: { Date(timeIntervalSince1970: Double(self.time) / 1000) }, output: { self.output.append($0) })
    }
}

struct UsageClearTests {
    private func stableEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }

    @Test func clearPersistsOrderingContinuityAndSchedulingThenFreshCollectionContinues() throws {
        let fixture = ClearFixture()
        let runtime = fixture.runtime()
        #expect(runtime.refresh().outcome == .refreshed)
        let before = try #require(fixture.durable.providers["codex"])
        let old = try #require(before.snapshot)
        fixture.messages = []
        let result = runtime.clear()
        #expect(result.outcome == .cleared && result.outcome.exitCode == 0)
        #expect(result.localCleared && result.publicationAttempted && !result.freshSnapshot)
        let after = try #require(fixture.durable.providers["codex"])
        #expect(after.snapshot == nil && after.latestInvalidationRevision > old.revision)
        #expect(after.revision > after.latestInvalidationRevision)
        #expect(after.accountFingerprint == before.accountFingerprint)
        #expect(after.fingerprintSalt == before.fingerprintSalt)
        #expect(after.lastFetchStartedAt == before.lastFetchStartedAt)
        #expect(after.retryNotBefore == before.retryNotBefore)
        #expect(after.temporaryFailureCount == before.temporaryFailureCount)
        #expect(after.status?.status == .pending)
        #expect(fixture.messages.map(\.0) == [UsageRuntime.statusNotification])
        #expect(runtime.refresh().outcome == .throttled)
        fixture.time += 30000
        #expect(runtime.refresh().outcome == .refreshed)
        let fresh = try #require(fixture.durable.providers["codex"]?.snapshot)
        #expect(fresh.revision > after.latestInvalidationRevision)
        #expect(fresh.collectedAt == old.collectedAt + 30000)
    }

    @Test func restartWithoutSnapshotReplaysOriginalMarkerAndRejectsLateSnapshotOffline() throws {
        let fixture = ClearFixture()
        #expect(fixture.runtime().refresh().outcome == .refreshed)
        let old = try #require(fixture.durable.providers["codex"]?.snapshot)
        fixture.time += 10
        let result = fixture.runtime().clear()
        let marker = try #require(fixture.durable.providers["codex"]?.status)
        fixture.runtime().report(result, json: true)
        let json = try #require(fixture.output.last)
        #expect(json.contains("\"localCleared\":true") && json.contains("\"publicationAttempted\":true"))
        #expect(!json.contains("receiver") && !json.contains("private-account"))
        // No receiver exists during the clear. Its later recovery includes only the committed marker.
        fixture.time += 1_000_000
        fixture.messages = []
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.fetchCount == 1 && fixture.identityReadCount == 0)
        #expect(fixture.messages.map(\.0) == [UsageRuntime.statusNotification])
        let now = Date(timeIntervalSince1970: Double(fixture.time) / 1000)
        #expect(try UsageWire().decodeStatus(#require(fixture.messages.first?.1), now: now) == marker)
        let payload = try UsageWire().encode(old, now: now)
        #expect(throws: UsageWireError.self) {
            try UsageWire().decodeSnapshot(payload, now: now, invalidation: marker.latestInvalidationRevision)
        }
    }

    @Test func preClearInFlightFetchCannotRestoreUsageOrOverwriteOtherProvider() {
        let fixture = ClearFixture()
        let runtime = fixture.runtime()
        var other = UsageProviderState()
        other.revision = 40
        fixture.durable.providers["claude"] = other
        fixture.onFetch = {
            #expect(runtime.clear().localCleared)
            fixture.durable.providers["claude"]?.revision = 41
        }
        let result = runtime.refresh()
        #expect(result.outcome == .invalidated && !result.freshSnapshot && !result.publicationAttempted)
        #expect(fixture.durable.providers["codex"]?.snapshot == nil)
        #expect(fixture.durable.providers["claude"]?.revision == 41)
        #expect(!fixture.messages.contains { $0.0 == UsageRuntime.snapshotNotification })
        fixture.onFetch = nil
        fixture.time += 30000
        #expect(runtime.refresh().outcome == .refreshed)
        #expect(fixture.durable.providers["claude"]?.revision == 41)
    }

    @Test func persistenceAndPublicationFailuresKeepTruthfulResultsAndRecovery() throws {
        let fixture = ClearFixture()
        #expect(fixture.runtime().refresh().outcome == .refreshed)
        let before = try stableEncoder().encode(fixture.durable)
        fixture.messages = []
        fixture.failSave = true
        let failed = fixture.runtime().clear()
        #expect(failed.outcome == .persistenceFailure && !failed.localCleared && !failed.publicationAttempted)
        #expect(try stableEncoder().encode(fixture.durable) == before)
        #expect(fixture.messages.isEmpty)
        fixture.failSave = false
        fixture.failPost = true
        let local = fixture.runtime().clear()
        #expect(local.outcome == .publicationFailure && local.localCleared && local.publicationAttempted)
        #expect(local.outcome.exitCode != 0)
        let marker = try #require(fixture.durable.providers["codex"]?.status)
        fixture.failPost = false
        fixture.messages = []
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.messages.count == 1)
        #expect(fixture.durable.providers["codex"]?.status == marker)
    }

    @Test func providerIsolationAndFailuresSurviveClear() throws {
        let fixture = ClearFixture()
        var state = UsageProviderState()
        state.revision = 10
        state.retryNotBefore = fixture.time + 90000
        state.temporaryFailureCount = 3
        state.status = UsageCollectionStatus(provider: .codex, revision: 10, observedAt: fixture.time,
                                             status: .throttled, retryAt: state.retryNotBefore)
        fixture.durable.providers["codex"] = state
        fixture.durable.providers["claude"] = state
        let other = try stableEncoder().encode(state)
        #expect(fixture.runtime().clear().outcome == .cleared)
        let cleared = try #require(fixture.durable.providers["codex"])
        #expect(cleared.status?.status == .throttled && cleared.status?.retryAt == state.retryNotBefore)
        #expect(cleared.retryNotBefore == state.retryNotBefore && cleared.temporaryFailureCount == 3)
        #expect(try stableEncoder().encode(#require(fixture.durable.providers["claude"])) == other)
        #expect(fixture.runtime().clear(provider: .claude).outcome == .unsupportedProvider)
    }
}
