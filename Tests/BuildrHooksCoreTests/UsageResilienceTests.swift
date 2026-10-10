@testable import BuildrHooksCore
import Darwin
import Foundation
import Testing

private struct UsageNotice {
    let name: String
    let payload: String
}

private final class InterruptedUsage: UsageFetching, UsageStateStoring, UsageNotifying, @unchecked Sendable {
    let file = UsageFileStateStore(fileURL: URL(fileURLWithPath: "/tmp/r-\(UUID().uuidString)/state.json"))
    var time: Int64 = 1_000_000_000
    var stopped = false
    var identity: String? = "private-account-A"
    var failure: UsageFetchError?
    var fetches = 0
    var saves = 0
    var failSave: Int?
    var failAfterSave = false
    var failLoad = false
    var failPublication = false
    var afterFetch: () -> Void = {}
    var afterSave: () -> Void = {}
    var afterIdentity: () -> Void = {}
    var notifications: [UsageNotice] = []

    deinit { try? FileManager.default.removeItem(at: file.fileURL.deletingLastPathComponent()) }
    func load() throws -> UsageDurableState {
        if failLoad {
            throw UsageWireError.invalidPayload
        }
        return try file.load()
    }

    func save(_ state: UsageDurableState) throws {
        saves += 1
        if saves == failSave {
            throw UsageWireError.invalidPayload
        }
        try file.save(state)
        afterSave()
        if failAfterSave {
            throw UsageWireError.invalidPayload
        }
    }

    func fetch(timeout _: TimeInterval) throws -> Data {
        fetches += 1
        if let failure {
            throw failure
        }
        afterFetch()
        return Data(#"{"accountId":"private-account-A","rateLimits":{"primary":{"usedPercent":25}}}"#.utf8)
    }

    func currentAccountIdentity(timeout _: TimeInterval) -> String? {
        afterIdentity()
        return identity
    }

    func post(name: String, payload: String) throws {
        if failPublication {
            throw UsageFetchError.temporaryFailure
        }
        notifications.append(UsageNotice(name: name, payload: payload))
    }

    func runtime() -> UsageRuntime {
        var runtime = UsageRuntime(fetcher: self, store: self, notifier: self,
                                   now: { Date(timeIntervalSince1970: Double(self.time) / 1000) }, output: { _ in })
        runtime.isCancelled = { self.stopped }
        return runtime
    }

    var snapshotPayloads: [String] {
        notifications.filter { $0.name == UsageRuntime.snapshotNotification }.map(\.payload)
    }
}

struct UsageResilienceTests {
    @Test func failedClearAcknowledgementReportsOnlyVerifiedLocalCommit() throws {
        for readable in [true, false] {
            let fixture = InterruptedUsage()
            _ = fixture.runtime().refresh()
            let oldRevision = try #require(fixture.load().providers["codex"]?.revision)
            fixture.notifications = []
            fixture.failAfterSave = true
            fixture.afterSave = { fixture.failLoad = !readable }
            let result = fixture.runtime().clear()
            #expect(result.outcome == .persistenceFailure && result.outcome.exitCode != 0)
            #expect(result.localCleared == readable && !result.publicationAttempted)
            #expect(fixture.notifications.isEmpty)
            let committed = try #require(fixture.file.load().providers["codex"])
            #expect(committed.snapshot == nil && committed.latestInvalidationRevision == oldRevision + 1)
            fixture.failLoad = false
            fixture.failAfterSave = false
            fixture.afterSave = {}
            fixture.runtime().recover(providers: [.codex])
            #expect(fixture.snapshotPayloads.isEmpty)
        }
    }

    @Test func corruptSchedulingFailsClosedWithoutFetchingOrResettingState() throws {
        let cases: [UsageProviderState] = [
            state(lastStart: Int64.max), state(lastStart: -1), state(retry: -1),
            state(failures: Int.max), state(failures: -1), state(failures: 21)
        ]
        for state in cases {
            let fixture = InterruptedUsage()
            var durable = UsageDurableState()
            durable.providers["codex"] = state
            try FileManager.default.createDirectory(at: fixture.file.fileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let bytes = try JSONEncoder().encode(durable)
            try bytes.write(to: fixture.file.fileURL)
            #expect(fixture.runtime().refresh().outcome == .persistenceFailure)
            #expect(fixture.runtime().clear().outcome == .persistenceFailure)
            fixture.runtime().recover(providers: [.codex])
            #expect(fixture.fetches == 0 && fixture.notifications.isEmpty)
            #expect(try Data(contentsOf: fixture.file.fileURL) == bytes)
            #expect(throws: UsageWireError.self) { try fixture.file.save(durable) }
        }
    }

    private func state(lastStart: Int64? = nil, retry: Int64? = nil, failures: Int? = nil) -> UsageProviderState {
        var state = UsageProviderState()
        state.lastFetchStartedAt = lastStart
        state.retryNotBefore = retry
        state.temporaryFailureCount = failures
        return state
    }

    @Test func schedulingArithmeticBoundaryAndLongRetryRemainSafe() throws {
        let fixture = InterruptedUsage()
        var state = UsageProviderState()
        state.lastFetchStartedAt = Int64.max - 30000
        state.retryNotBefore = Int64.max
        state.temporaryFailureCount = 20
        var durable = UsageDurableState()
        durable.providers["codex"] = state
        try fixture.file.save(durable)
        #expect(fixture.runtime().refresh().retryAt == Int64.max)
        fixture.identity = nil
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.fetches == 0 && fixture.snapshotPayloads.isEmpty)
        #expect(try fixture.load().providers["codex"]?.retryNotBefore == Int64.max)
    }

    @Test func failureBackoffSurvivesClearAndRestart() throws {
        let fixture = InterruptedUsage()
        fixture.failure = .temporaryFailure
        var first = fixture.runtime()
        first.jitter = { 0 }
        #expect(first.refresh().retryAt == fixture.time + 30000)
        #expect(first.clear().outcome == .cleared)
        let state = try #require(fixture.load().providers["codex"])
        #expect(state.temporaryFailureCount == 1)
        var restarted = fixture.runtime()
        restarted.jitter = { 0 }
        #expect(restarted.refresh().outcome == .throttled)
        fixture.time += 30000
        #expect(restarted.refresh().retryAt == fixture.time + 60000)
        #expect(try fixture.load().providers["codex"]?.temporaryFailureCount == 2)
    }

    @Test func cancellationDuringFetchStartCommitDoesNotStartProvider() throws {
        let fixture = InterruptedUsage()
        fixture.afterSave = { fixture.stopped = true }
        #expect(fixture.runtime().refresh().outcome == .cancelled)
        #expect(fixture.fetches == 0 && fixture.notifications.isEmpty)
        #expect(try fixture.load().providers["codex"]?.status?.status == .pending)
    }

    @Test func interruptedFinalCommitRetainsEarlierObservationAndFetchSpacing() throws {
        let fixture = InterruptedUsage()
        #expect(fixture.runtime().refresh().outcome == .refreshed)
        let original = try #require(fixture.load().providers["codex"]?.snapshot)
        fixture.time += 40000
        fixture.failSave = fixture.saves + 2
        #expect(fixture.runtime().refresh().outcome == .persistenceFailure)
        let committed = try #require(fixture.load().providers["codex"])
        #expect(committed.snapshot == original && committed.status?.status == .pending)
        fixture.notifications = []
        let restarted = fixture.runtime()
        restarted.recover(providers: [.codex])
        #expect(fixture.snapshotPayloads.count == 1)
        #expect(restarted.refresh().outcome == .throttled)
        #expect(fixture.fetches == 2)
        let replay = try UsageWire().decodeSnapshot(#require(fixture.snapshotPayloads.first),
                                                    now: Date(timeIntervalSince1970: Double(fixture.time) / 1000))
        #expect(replay == original)
    }

    @Test func clearCommitAndPublicationInterruptionCannotRestoreInvalidatedUsage() throws {
        let fixture = InterruptedUsage()
        _ = fixture.runtime().refresh()
        let old = try #require(fixture.load().providers["codex"]?.snapshot)
        fixture.failSave = fixture.saves + 1
        let failedClear = fixture.runtime().clear()
        #expect(!failedClear.localCleared && failedClear.outcome == .persistenceFailure)
        #expect(try fixture.load().providers["codex"]?.snapshot == old)
        fixture.failPublication = true
        let cleared = fixture.runtime().clear()
        #expect(cleared.localCleared && cleared.outcome == .publicationFailure && cleared.publicationAttempted)
        let marker = try #require(fixture.load().providers["codex"]?.latestInvalidationRevision)
        fixture.failPublication = false
        fixture.notifications = []
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.snapshotPayloads.isEmpty)
        let payload = try #require(fixture.notifications.last?.payload)
        let date = Date(timeIntervalSince1970: Double(fixture.time) / 1000)
        #expect(try UsageWire().decodeStatus(payload, now: date).latestInvalidationRevision == marker)
        #expect(throws: UsageWireError.self) {
            try UsageWire().decodeSnapshot(UsageWire().encode(old, now: date), now: date, invalidation: marker)
        }
    }

    @Test func restartRetainsProviderRetryAndChecksAccountBeforeReplay() throws {
        let fixture = InterruptedUsage()
        _ = fixture.runtime().refresh()
        fixture.time += 40000
        fixture.failure = .throttled(retryAt: fixture.time + 900_000)
        _ = fixture.runtime().refresh()
        let restricted = try #require(fixture.load().providers["codex"])
        fixture.identity = "private-account-B"
        fixture.notifications = []
        let restarted = fixture.runtime()
        restarted.recover(providers: [.codex])
        let recovered = try #require(fixture.load().providers["codex"])
        #expect(recovered.snapshot == nil && recovered.latestInvalidationRevision > 0)
        #expect(recovered.retryNotBefore == restricted.retryNotBefore)
        #expect(restarted.refresh().retryAt == restricted.retryNotBefore)
        #expect(fixture.fetches == 2 && fixture.snapshotPayloads.isEmpty)
        #expect(!fixture.notifications.map(\.payload).joined().contains("private-account"))
    }

    @Test func lateFetchAndCancelledRecoveryAreWithheld() throws {
        let fixture = InterruptedUsage()
        fixture.afterFetch = { fixture.stopped = true }
        #expect(fixture.runtime().refresh().outcome == .cancelled)
        #expect(try fixture.load().providers["codex"]?.snapshot == nil)
        #expect(fixture.snapshotPayloads.isEmpty)
        fixture.stopped = false
        fixture.afterFetch = {}
        fixture.time += 40000
        _ = fixture.runtime().refresh()
        let before = try Data(contentsOf: fixture.file.fileURL)
        fixture.notifications = []
        fixture.afterIdentity = { fixture.stopped = true }
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.notifications.isEmpty)
        #expect(try Data(contentsOf: fixture.file.fileURL) == before)
    }

    @Test func cancellationAfterCommitKeepsRecoveryButSuppressesPublication() throws {
        let fixture = InterruptedUsage()
        fixture.afterSave = {
            if fixture.saves == 2 {
                fixture.stopped = true
            }
        }
        #expect(fixture.runtime().refresh().outcome == .cancelled)
        let committed = try #require(fixture.load().providers["codex"]?.snapshot)
        #expect(fixture.snapshotPayloads.isEmpty)
        fixture.stopped = false
        fixture.afterSave = {}
        fixture.notifications = []
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.snapshotPayloads.count == 1)
        #expect(try fixture.load().providers["codex"]?.snapshot == committed)
    }

    @Test func abandonedTemporaryWriteAndCorruptOrderingCannotResetCommittedState() throws {
        let fixture = InterruptedUsage()
        _ = fixture.runtime().refresh()
        let bytes = try Data(contentsOf: fixture.file.fileURL)
        let partial = fixture.file.fileURL.deletingLastPathComponent().appendingPathComponent(".usage-interrupted")
        try Data("{partial".utf8).write(to: partial)
        #expect(try Data(contentsOf: fixture.file.fileURL) == bytes)
        _ = try fixture.load()
        var corrupt = try fixture.load()
        corrupt.providers["codex"]?.revision = 0
        try JSONEncoder().encode(corrupt).write(to: fixture.file.fileURL)
        #expect(fixture.runtime().refresh().outcome == .persistenceFailure)
        fixture.notifications = []
        fixture.runtime().recover(providers: [.codex])
        #expect(fixture.notifications.isEmpty && fixture.fetches == 1)
    }

    @Test func ownedChildGetsFiveSecondsAndUnrelatedChildIsUntouched() {
        var time: TimeInterval = 0
        var owned = true
        let unrelated = true
        var closed = false
        var requested = false
        var killed = false
        UsageOwnedProcessShutdown(running: { owned }, closeInput: { closed = true },
                                  requestTermination: { requested = true },
                                  forceTermination: { killed = true; owned = false },
                                  now: { time }, wait: { time += $0 }).stop()
        #expect(closed && requested && killed && !owned && unrelated)
        #expect(abs(time - 5) < 0.00001)
        killed = false
        owned = true
        time = 0
        UsageOwnedProcessShutdown(running: { owned }, closeInput: {}, requestTermination: {},
                                  forceTermination: { killed = true }, now: { time },
                                  wait: {
                                      time += $0; if time >= 1 {
                                          owned = false
                                      }
                                  }).stop()
        #expect(!killed && time < 5)
    }

    @Test func staleEndpointIsReplacedOnlyAfterExclusiveOwnership() throws {
        let cache = URL(fileURLWithPath: "/tmp/r-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let owner = UsageCoordination(cacheURL: cache)
        defer { owner.close() }
        #expect(try owner.acquire())
        let descriptor = try UsageCoordination.makeSocket()
        #expect(try UsageCoordination.withAddress(owner.socketURL.path) { bind(descriptor, $0, $1) } == 0)
        Darwin.close(descriptor) // Simulate a crashed endpoint, leaving the socket path.
        try owner.startServing()
        let other = UsageCoordination(cacheURL: cache)
        #expect(try !other.acquire())
        #expect(throws: UsageCoordinationError.self) { try other.startServing() }
        other.close()
        #expect(FileManager.default.fileExists(atPath: owner.socketURL.path))
        owner.close()
        #expect(!FileManager.default.fileExists(atPath: owner.socketURL.path))
        #expect(FileManager.default.fileExists(atPath: owner.lockURL.path))
    }
}
