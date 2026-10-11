@testable import BuildrHooksCore
import Foundation
import Testing

private final class RecoveryFixture: UsageFetching, UsageStateStoring, UsageNotifying, @unchecked Sendable {
    var durable = UsageDurableState()
    var identity: String? = "account-A"
    var fullIdentity: String? = "account-A"
    var usable = true
    var failure: UsageFetchError?
    var disconnected = false
    var failSave = false
    var fetchCount = 0
    var messages: [(String, String)] = []
    var time: Int64 = 1_000_000_000
    var stopped = false
    func load() -> UsageDurableState {
        durable
    }

    func save(_ state: UsageDurableState) throws {
        if failSave {
            throw UsageWireError.invalidPayload
        }
        durable = state
    }

    func post(name: String, payload: String) {
        messages.append((name, payload))
    }

    func currentAccountIdentity(timeout: TimeInterval) -> String? {
        #expect(timeout == 5)
        return identity
    }

    func events() throws -> [UsageWatchTrigger] {
        if disconnected {
            throw UsageFetchError.temporaryFailure
        }
        return []
    }

    func fetch(timeout _: TimeInterval) throws -> Data {
        fetchCount += 1
        if let failure {
            throw failure
        }
        var response: [String: Any] = ["rateLimits": usable ? ["primary": ["usedPercent": 12]] : [:]]
        if let fullIdentity {
            response["accountId"] = fullIdentity
        }
        return try JSONSerialization.data(withJSONObject: response)
    }

    func runtime() -> UsageRuntime {
        var runtime = UsageRuntime(fetcher: self, store: self, notifier: self,
                                   now: { Date(timeIntervalSince1970: Double(self.time) / 1000) }, output: { _ in })
        runtime.isCancelled = { self.stopped }
        return runtime
    }

    var snapshots: [String] {
        messages.filter { $0.0 == UsageRuntime.snapshotNotification }.map(\.1)
    }

    var statuses: [String] {
        messages.filter { $0.0 == UsageRuntime.statusNotification }.map(\.1)
    }
}

struct UsageRecoveryTests {
    @Test func verifiedRestartReplaysOriginalSnapshotAndIndependentFailureStatus() throws {
        let fixture = RecoveryFixture()
        #expect(fixture.runtime().refresh().outcome == .refreshed)
        let original = try #require(fixture.durable.providers["codex"]?.snapshot)
        fixture.time += 40000
        fixture.usable = false
        #expect(fixture.runtime().refresh().outcome == .usageUnavailable)
        let failure = try #require(fixture.durable.providers["codex"]?.status)
        fixture.time += 1_000_000
        fixture.messages = []
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.fetchCount == 2)
        #expect(try UsageWire().decodeSnapshot(#require(fixture.snapshots.first), now: Date(
            timeIntervalSince1970: Double(fixture.time) / 1000
        )) == original)
        #expect(try UsageWire().decodeStatus(#require(fixture.statuses.last), now: Date(
            timeIntervalSince1970: Double(fixture.time) / 1000
        )) == failure)
        #expect(failure.revision > original.revision)
        let encodedState = try JSONEncoder().encode(fixture.durable)
        let privateState = try #require(String(bytes: encodedState, encoding: .utf8))
        #expect(!privateState.contains("account-A"))
        #expect(!fixture.messages.map(\.1).joined().contains("Fingerprint"))
    }

    @Test func missingIdentityWithholdsRestartUntilFreshUsableFetch() {
        for observationIdentity in [Optional("account-A"), nil] {
            let fixture = RecoveryFixture()
            fixture.fullIdentity = observationIdentity
            #expect(fixture.runtime().refresh().outcome == .refreshed)
            fixture.identity = nil
            fixture.messages = []
            let restarted = fixture.runtime()
            restarted.recover(providers: [.codex])
            #expect(fixture.snapshots.isEmpty)
            #expect(fixture.durable.providers["codex"]?.status?.status == .pending)
            #expect(fixture.fetchCount == 1)
            fixture.time += 40000
            fixture.fullIdentity = nil
            #expect(restarted.refresh().outcome == .refreshed)
            fixture.messages = []
            restarted.recover(providers: [.codex])
            #expect(fixture.snapshots.count == 1)
            // A fresh identity-free observation is useful now, but cannot prove a later restart.
            fixture.messages = []
            fixture.runtime().recover(providers: [.codex])
            #expect(fixture.snapshots.isEmpty)
        }
    }

    @Test func fullAccountSwitchInvalidatesBeforeUnavailableNewUsageAndRejectsDelayedData() throws {
        let fixture = RecoveryFixture()
        let runtime = fixture.runtime()
        #expect(runtime.refresh().outcome == .refreshed)
        let old = try #require(fixture.durable.providers["codex"]?.snapshot)
        fixture.time += 40000
        fixture.fullIdentity = "account-B"
        fixture.identity = "account-B"
        fixture.usable = false
        #expect(runtime.refresh().outcome == .usageUnavailable)
        let state = try #require(fixture.durable.providers["codex"])
        #expect(state.snapshot == nil)
        #expect(state.latestInvalidationRevision > old.revision)
        #expect(state.status?.latestInvalidationRevision == state.latestInvalidationRevision)
        fixture.messages = []
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.snapshots.isEmpty)
        #expect(fixture.statuses.count == 1)
        let wire = UsageWire()
        let now = Date(timeIntervalSince1970: Double(fixture.time) / 1000)
        let delayed = try wire.encode(old, now: now)
        #expect(throws: UsageWireError.self) {
            try wire.decodeSnapshot(delayed, now: now, invalidation: state.latestInvalidationRevision)
        }
    }

    @Test func identityReadSwitchPersistsInvalidationAndRecoveryDoesNotFetch() throws {
        let fixture = RecoveryFixture()
        _ = fixture.runtime().refresh()
        let oldRevision = try #require(fixture.durable.providers["codex"]?.snapshot?.revision)
        fixture.identity = "account-B"
        fixture.messages = []
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.fetchCount == 1)
        #expect(fixture.snapshots.isEmpty)
        let state = try #require(fixture.durable.providers["codex"])
        #expect(state.latestInvalidationRevision > oldRevision)
        #expect(state.snapshot == nil)
        #expect(state.status?.status == .pending)
    }

    @Test func recoveryBurstsAreGlobalAndDoNotBypassFetchRestrictions() {
        let fixture = RecoveryFixture()
        let runtime = fixture.runtime()
        _ = runtime.refresh()
        fixture.messages = []
        runtime.recover(providers: [.codex, .claude])
        runtime.recover(providers: [.codex])
        fixture.time += 999
        runtime.recover(providers: [.codex])
        #expect(fixture.snapshots.count == 1)
        fixture.time += 1
        runtime.recover(providers: [.codex])
        #expect(fixture.snapshots.count == 2)
        #expect(fixture.fetchCount == 1)
        #expect(runtime.refresh().outcome == .throttled)
    }

    @Test func recoveryReplaysEveryAvailableSelectedProviderAsOneCoalescedReply() throws {
        let fixture = RecoveryFixture()
        var runtime = fixture.runtime()
        runtime.additionalFetchers[.claude] = fixture
        _ = runtime.refresh(provider: .codex)
        _ = runtime.refresh(provider: .claude)
        fixture.messages = []
        runtime.recover(providers: [.claude, .codex, .codex])
        runtime.recover(providers: [.claude])
        #expect(fixture.snapshots.count == 2)
        #expect(fixture.statuses.count == 2)
        #expect(fixture.fetchCount == 2)
        let now = Date(timeIntervalSince1970: Double(fixture.time) / 1000)
        let providers = try fixture.snapshots.map { try UsageWire().decodeSnapshot($0, now: now).provider }
        #expect(Set(providers) == Set([UsageProvider.codex, .claude]))
    }

    @Test func sparseAuthenticationEventRevokesContinuityBeforeSameTickRecovery() {
        let fixture = RecoveryFixture()
        _ = fixture.runtime().refresh()
        fixture.identity = nil
        fixture.messages = []
        fixture.runtime().watch(providers: [.codex], triggers: { [.authenticationChanged, .recoveryRequested] },
                                wait: { _ in fixture.stopped = true })
        #expect(fixture.fetchCount == 1)
        #expect(fixture.snapshots.isEmpty)
        #expect(fixture.durable.providers["codex"]?.status?.status == .pending)
    }

    @Test func connectionLossRevokesSessionProofWhileFetchIsStillThrottled() {
        let fixture = RecoveryFixture()
        let runtime = fixture.runtime()
        _ = runtime.refresh()
        fixture.identity = nil
        fixture.disconnected = true
        fixture.messages = []
        runtime.watch(providers: [.codex], triggers: { [.recoveryRequested] },
                      wait: { _ in fixture.stopped = true })
        #expect(fixture.snapshots.isEmpty)
        #expect(fixture.fetchCount == 1)
    }

    @Test func failedOrUnavailableIdentityFreeFullReadRevokesPriorSessionProof() {
        for failure in [Optional(UsageFetchError.authenticationRequired), .temporaryFailure, nil] {
            let fixture = RecoveryFixture()
            let runtime = fixture.runtime()
            _ = runtime.refresh()
            fixture.time += 40000
            fixture.identity = nil
            fixture.fullIdentity = nil
            fixture.failure = failure
            fixture.usable = false
            #expect(runtime.refresh().outcome != .refreshed)
            fixture.messages = []
            runtime.recover(providers: [.codex])
            #expect(fixture.snapshots.isEmpty)
            #expect(fixture.statuses.count == 1)
            #expect(fixture.durable.providers["codex"]?.snapshot != nil)
        }
    }

    @Test func failedInvalidationCommitNeverPublishesOldAccountUsage() {
        let fixture = RecoveryFixture()
        _ = fixture.runtime().refresh()
        fixture.identity = "account-B"
        fixture.failSave = true
        fixture.messages = []
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.snapshots.isEmpty)
        #expect(fixture.fetchCount == 1)
    }
}
