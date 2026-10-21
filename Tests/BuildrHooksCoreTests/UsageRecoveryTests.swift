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

struct UsagePublisherVersionTests {
    @Test func currentPublisherVersionCoversRefreshAndPreFieldRecovery() throws {
        let fixture = RecoveryFixture()
        var publisher = fixture.runtime()
        publisher = UsageRuntime(fetcher: fixture, store: fixture, notifier: fixture, cliVersion: "2.0.0",
                                 now: publisher.now, output: { _ in })
        #expect(publisher.refresh().outcome == .refreshed)
        let original = fixture.durable
        #expect(original.providers["codex"]?.snapshot?.cliVersion == nil)
        #expect(original.providers["codex"]?.status?.cliVersion == nil)
        #expect(fixture.messages.count == 3) // Pending, snapshot, ready.
        for message in fixture.messages {
            let json = try #require(JSONSerialization.jsonObject(with: Data(message.1.utf8)) as? [String: Any])
            #expect(json["cliVersion"] as? String == "2.0.0")
        }
        // Simulate loading a pre-field cache with the current publisher after an upgrade.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let cache = try encoder.encode(original)
        #expect(try !#require(String(bytes: cache, encoding: .utf8)).contains("cliVersion"))
        fixture.durable = try JSONDecoder().decode(UsageDurableState.self, from: cache)
        fixture.messages = []
        let restarted = UsageRuntime(fetcher: fixture, store: fixture, notifier: fixture, cliVersion: "2.1.0",
                                     now: publisher.now, output: { _ in })
        restarted.recover(providers: [.codex])
        #expect(fixture.fetchCount == 1)
        let now = publisher.now()
        var snapshot = try UsageWire().decodeSnapshot(#require(fixture.snapshots.first), now: now)
        var status = try UsageWire().decodeStatus(#require(fixture.statuses.first), now: now)
        #expect(snapshot.cliVersion == "2.1.0" && status.cliVersion == "2.1.0")
        snapshot.cliVersion = nil
        status.cliVersion = nil
        #expect(snapshot == original.providers["codex"]?.snapshot)
        #expect(status == original.providers["codex"]?.status)
        #expect(try encoder.encode(fixture.durable) == cache)
    }

    @Test func freshWatchPublicationCarriesCurrentVersionWithoutPersistingIt() throws {
        let fixture = RecoveryFixture()
        var runtime = UsageRuntime(fetcher: fixture, store: fixture, notifier: fixture, cliVersion: "2.1.0",
                                   now: { Date(timeIntervalSince1970: Double(fixture.time) / 1000) }, output: { _ in })
        runtime.isCancelled = { fixture.stopped }
        runtime.watch(providers: [.codex], wait: { _ in fixture.stopped = true })
        #expect(fixture.fetchCount == 1)
        #expect(fixture.snapshots.count == 1)
        let snapshot = try UsageWire().decodeSnapshot(#require(fixture.snapshots.first), now: runtime.now())
        #expect(snapshot.cliVersion == "2.1.0")
        #expect(snapshot.collectedAt == fixture.time)
        #expect(snapshot.revision == fixture.durable.providers["codex"]?.snapshot?.revision)
        for payload in fixture.statuses {
            #expect(try UsageWire().decodeStatus(payload, now: runtime.now()).cliVersion == "2.1.0")
        }
        #expect(fixture.durable.providers["codex"]?.snapshot?.cliVersion == nil)
        #expect(fixture.durable.providers["codex"]?.status?.cliVersion == nil)
    }

    @Test func watchFailureAndClearCarryCurrentPublisherVersion() throws {
        let fixture = RecoveryFixture()
        let restarted = UsageRuntime(fetcher: fixture, store: fixture, notifier: fixture, cliVersion: "2.1.0",
                                     now: { Date(timeIntervalSince1970: Double(fixture.time) / 1000) },
                                     output: { _ in })
        _ = restarted.refresh()
        let revision = try #require(fixture.durable.providers["codex"]?.snapshot?.revision)
        fixture.time += 40000
        fixture.failure = .temporaryFailure
        fixture.messages = []
        var watching = restarted
        watching.isCancelled = { fixture.stopped }
        watching.watch(providers: [.codex], triggers: { [.recoveryRequested] },
                       wait: { _ in fixture.stopped = true })
        #expect(fixture.fetchCount == 2)
        #expect(!fixture.statuses.isEmpty && fixture.snapshots.count == 1)
        for message in fixture.messages {
            let json = try #require(JSONSerialization.jsonObject(with: Data(message.1.utf8)) as? [String: Any])
            #expect(json["cliVersion"] as? String == "2.1.0")
        }
        fixture.stopped = false
        fixture.messages = []
        _ = restarted.clear(provider: .codex)
        let invalidated = try UsageWire().decodeStatus(#require(fixture.statuses.last), now: restarted.now())
        #expect(invalidated.cliVersion == "2.1.0")
        #expect(invalidated.latestInvalidationRevision > revision)
    }

    @Test func replayReplacesRetainedPublisherVersionWithoutChangingObservation() throws {
        let fixture = RecoveryFixture()
        _ = fixture.runtime().refresh()
        fixture.durable.providers["codex"]?.snapshot?.cliVersion = "1.0.0"
        fixture.durable.providers["codex"]?.status?.cliVersion = "1.0.0"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let retained = try encoder.encode(fixture.durable)
        fixture.messages = []
        let runtime = UsageRuntime(fetcher: fixture, store: fixture, notifier: fixture, cliVersion: "3.0.0",
                                   now: { Date(timeIntervalSince1970: Double(fixture.time) / 1000) }, output: { _ in })
        runtime.recover(providers: [.codex])
        let snapshot = try UsageWire().decodeSnapshot(#require(fixture.snapshots.first), now: runtime.now())
        #expect(snapshot.cliVersion == "3.0.0")
        let status = try UsageWire().decodeStatus(#require(fixture.statuses.first), now: runtime.now())
        #expect(status.cliVersion == "3.0.0")
        #expect(try encoder.encode(fixture.durable) == retained)
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

    @Test func recoveryCoalescesCodexAndWithholdsUnsupportedClaudeV1() throws {
        let fixture = RecoveryFixture()
        var runtime = fixture.runtime()
        runtime.additionalFetchers[.claude] = fixture
        _ = runtime.refresh(provider: .codex)
        _ = runtime.refresh(provider: .claude)
        fixture.messages = []
        runtime.recover(providers: [.claude, .codex, .codex])
        runtime.recover(providers: [.claude])
        #expect(fixture.snapshots.count == 1)
        #expect(fixture.statuses.count == 1)
        #expect(fixture.fetchCount == 2)
        let now = Date(timeIntervalSince1970: Double(fixture.time) / 1000)
        let providers = try fixture.snapshots.map { try UsageWire().decodeSnapshot($0, now: now).provider }
        #expect(Set(providers) == Set([UsageProvider.codex]))
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
