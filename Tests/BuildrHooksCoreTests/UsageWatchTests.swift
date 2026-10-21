@testable import BuildrHooksCore
import Foundation
import Testing

private final class WatchClock: @unchecked Sendable {
    private let lock = NSLock()
    private var seconds: Double = 0
    private var stopped = false
    func now() -> Date {
        lock.withLock { Date(timeIntervalSince1970: 1_000_000 + seconds) }
    }

    var elapsed: Double {
        lock.withLock { seconds }
    }

    var cancelled: Bool {
        lock.withLock { stopped }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    func advance(_ value: Double) {
        lock.withLock { seconds += value }
    }
}

private final class WatchProvider: UsageFetching, @unchecked Sendable {
    let clock: WatchClock
    var starts: [Double] = []
    var closed = false
    var failure: UsageFetchError?
    var event: @Sendable (Double) -> [UsageWatchTrigger] = { _ in [] }
    var onFetch: @Sendable () -> Void = {}
    init(_ clock: WatchClock) {
        self.clock = clock
    }

    func fetch(timeout: TimeInterval) throws -> Data {
        #expect(timeout == 30)
        starts.append(clock.elapsed)
        onFetch()
        if let failure {
            throw failure
        }
        return Data(#"{"rateLimits":{"primary":{"usedPercent":12}}}"#.utf8)
    }

    func events() -> [UsageWatchTrigger] {
        event(clock.elapsed)
    }

    func close() {
        closed = true
    }
}

private struct WatchNotifier: UsageNotifying {
    func post(name _: String, payload _: String) {}
}

struct UsageWatchTests {
    private func store() throws -> UsageFileStateStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return UsageFileStateStore(fileURL: directory.appendingPathComponent("state.json"))
    }

    private func runtime(_ provider: WatchProvider, _ store: UsageFileStateStore) -> UsageRuntime {
        var runtime = UsageRuntime(fetcher: provider, store: store, notifier: WatchNotifier(),
                                   now: { provider.clock.now() }, output: { _ in })
        runtime.isCancelled = { provider.clock.cancelled }
        runtime.jitter = { 0 }
        return runtime
    }

    @Test func startupPollWakeAndBurstEventsOnlyPublishFullFreshObservations() throws {
        let clock = WatchClock()
        let provider = WatchProvider(clock)
        provider.event = { time in time >= 1 && time < 3 ? [.limitsChanged, .limitsChanged] : [] }
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let runtime = runtime(provider, store)
        runtime.watch(providers: [.codex, .codex], triggers: {
            clock.elapsed == 340 ? [.wake, .refresh] : []
        }, wait: { _ in
            clock.advance(1)
            if clock.elapsed > 341 {
                clock.stop()
            }
        })
        #expect(provider.starts == [0, 30, 330])
        // Wake at 340 coalesces at the earliest permitted start (360), beyond this run.
        let state = try #require(store.load().providers["codex"])
        #expect(state.snapshot?.collectedAt == 1_000_330_000)
        #expect(state.status?.status == .ready)
        #expect(try #require(state.status).revision > (state.snapshot?.revision ?? 0))
        #expect(provider.closed)
    }

    @Test func wakeRequestsImmediateReadWhenSpacingAllows() throws {
        let clock = WatchClock()
        let provider = WatchProvider(clock)
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        runtime(provider, store).watch(providers: [.codex], triggers: {
            clock.elapsed == 40 ? [.wake] : []
        }, wait: { _ in
            clock.advance(1)
            if clock.elapsed > 41 {
                clock.stop()
            }
        })
        #expect(provider.starts == [0, 40])
        #expect(try store.load().providers["codex"]?.snapshot?.collectedAt == 1_000_040_000)
    }

    @Test func codexTemporaryRetryAndReservedClaudeV1AreIndependent() throws {
        let clock = WatchClock()
        let failing = WatchProvider(clock)
        failing.failure = .temporaryFailure
        let healthy = WatchProvider(clock)
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var runtime = runtime(failing, store)
        runtime.additionalFetchers[.claude] = healthy
        runtime.watch(providers: [.codex, .claude], wait: { _ in
            clock.advance(1)
            if clock.elapsed > 301 {
                clock.stop()
            }
        })
        #expect(failing.starts == [0, 30, 90, 210])
        #expect(healthy.starts.isEmpty) // Unsupported Claude v1 is rejected before provider I/O.
        let state = try store.load()
        #expect(state.providers["codex"]?.snapshot == nil)
        #expect(state.providers["codex"]?.status?.status == .temporaryFailure)
        #expect(state.providers["claude"] == nil) // Claude v1 cannot enter the durable store.
    }

    @Test func persistedRestrictionsApplyAcrossOneShotInstancesAndJitterIsBounded() throws {
        for random in [0.0, 1.0] {
            let clock = WatchClock()
            let provider = WatchProvider(clock)
            provider.failure = .temporaryFailure
            let store = try store()
            defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
            var first = runtime(provider, store)
            first.jitter = { random }
            let failed = first.refresh()
            #expect(failed.outcome == .temporaryFailure)
            let retry = try #require(failed.retryAt)
            #expect((1_000_030_000 ... 1_000_036_000).contains(retry))
            #expect(runtime(provider, store).refresh().outcome == .throttled)
            #expect(provider.starts == [0])
            clock.advance(40)
            provider.failure = .throttled(retryAt: 1_001_000_000)
            #expect(runtime(provider, store).refresh().retryAt == 1_001_000_000)
            clock.advance(300)
            #expect(runtime(provider, store).refresh().retryAt == 1_001_000_000)
            #expect(provider.starts == [0, 40])
        }
    }

    @Test func authenticationWaitsForAuthEventOrPoll() throws {
        let clock = WatchClock()
        let provider = WatchProvider(clock)
        provider.failure = .authenticationRequired
        provider.event = { time in
            if time == 1 {
                return [.limitsChanged]
            }
            if time == 60 {
                return [.authenticationChanged]
            }
            return []
        }
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let runtime = runtime(provider, store)
        runtime.watch(providers: [.codex], wait: { _ in
            clock.advance(1)
            if clock.elapsed > 361 {
                clock.stop()
            }
        })
        #expect(provider.starts == [0, 60, 360])
    }

    @Test func retriesCapAtFiveMinutesAndUnavailableKeepsLastObservation() throws {
        let clock = WatchClock()
        let provider = WatchProvider(clock)
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var runtime = runtime(provider, store)
        #expect(runtime.refresh().outcome == .refreshed)
        let original = try #require(store.load().providers["codex"]?.snapshot)
        clock.advance(40)
        provider.failure = .unavailable
        #expect(runtime.refresh().outcome == .usageUnavailable)
        #expect(try store.load().providers["codex"]?.snapshot == original)
        clock.advance(40)
        provider.failure = .timeout
        runtime.jitter = { 1 }
        for _ in 0 ..< 8 {
            let result = runtime.refresh()
            #expect(result.outcome == .timeout)
            let retry = try #require(result.retryAt)
            let duration = Double(retry) / 1000 - clock.now().timeIntervalSince1970
            #expect(duration >= 30 && duration <= 300)
            clock.advance(duration)
        }
        #expect(try store.load().providers["codex"]?.snapshot == original)
        #expect(runtime.refresh(provider: .claude).outcome == .unsupportedProvider)
    }

    @Test func cancellationDuringFetchNeverCommitsIncompleteObservation() throws {
        let clock = WatchClock()
        let provider = WatchProvider(clock)
        let store = try store()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let runtime = runtime(provider, store)
        #expect(runtime.refresh().outcome == .refreshed)
        let original = try #require(store.load().providers["codex"]?.snapshot)
        clock.advance(40)
        provider.onFetch = { clock.stop() }
        runtime.watch(providers: [.codex], wait: { _ in clock.advance(1) })
        #expect(try store.load().providers["codex"]?.snapshot == original)
        #expect(provider.closed)
    }
}
