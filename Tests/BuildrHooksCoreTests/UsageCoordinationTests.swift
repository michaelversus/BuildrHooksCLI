@testable import BuildrHooksCore
import Darwin
import Foundation
import Testing

final class CoordinatedProvider: UsageFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var count: Int {
        lock.withLock { calls }
    }

    func fetch(timeout _: TimeInterval) -> Data {
        lock.withLock { calls += 1 }
        return Data(#"{"rateLimits":{"primary":{"usedPercent":12}}}"#.utf8)
    }
}

private final class CancellableCoordinationProvider: UsageFetching, @unchecked Sendable {
    let onFetch: @Sendable () -> Void
    init(onFetch: @escaping @Sendable () -> Void = {}) {
        self.onFetch = onFetch
    }

    func fetch(timeout _: TimeInterval) throws -> Data {
        throw UsageFetchError.temporaryFailure
    }

    func fetch(timeout: TimeInterval, isCancelled: @escaping @Sendable () -> Bool) throws -> Data {
        onFetch()
        let deadline = UsageCoordination.time + min(0.5, timeout)
        while !isCancelled(), UsageCoordination.time < deadline {
            Thread.sleep(forTimeInterval: 0.001)
        }
        if isCancelled() {
            throw UsageFetchError.cancelled
        }
        throw UsageFetchError.timeout
    }
}

struct CoordinationNotifier: UsageNotifying {
    func post(name _: String, payload _: String) {}
}

final class CoordinationCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var output: [String] {
        lock.withLock { values }
    }

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }
}

struct UsageCoordinationTests {
    func fixture() -> UsageFileStateStore {
        UsageFileStateStore(fileURL: URL(fileURLWithPath: "/tmp/u-\(UUID().uuidString)/state.json"))
    }

    func runtime(_ provider: CoordinatedProvider, _ store: UsageFileStateStore,
                 capture: CoordinationCapture = CoordinationCapture()) -> UsageRuntime {
        UsageRuntime(fetcher: provider, store: store, notifier: CoordinationNotifier(), output: { capture.append($0) })
    }

    func connect(_ server: UsageCoordination) throws -> Int32 {
        let descriptor = try UsageCoordination.makeSocket()
        let result = try UsageCoordination.withAddress(server.socketURL.path) { Darwin.connect(descriptor, $0, $1) }
        guard result == 0 else { Darwin.close(descriptor); throw UsageCoordinationError.unavailable }
        return descriptor
    }

    @Test func exclusiveOwnershipRaceAndLockInodeSurvivesRelease() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let owners = (0 ..< 12).map { _ in UsageCoordination(cacheURL: store.fileURL) }
        let winners = CoordinationCapture()
        DispatchQueue.concurrentPerform(iterations: owners.count) { index in
            if (try? owners[index].acquire()) == true {
                winners.append(String(index))
            }
        }
        #expect(winners.output.count == 1)
        var before = stat()
        #expect(lstat(owners[0].lockURL.path, &before) == 0)
        owners.forEach { $0.close() }
        #expect(try owners[0].acquire())
        var after = stat()
        #expect(lstat(owners[0].lockURL.path, &after) == 0)
        #expect(before.st_ino == after.st_ino)
        #expect(after.st_mode & 0o077 == 0)
    }

    @Test func fallbackCollectsActualResultAndSharesThrottleAcrossOwners() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let provider = CoordinatedProvider()
        let capture = CoordinationCapture()
        let runtime = runtime(provider, store, capture: capture)
        let first = UsageCoordination(cacheURL: store.fileURL).refresh(runtime: runtime)
        #expect(first.outcome == .refreshed && first.freshSnapshot && first.publicationAttempted)
        runtime.report(first, json: true)
        let decoded = try JSONDecoder().decode(UsageRefreshResult.self, from: Data(#require(capture.output.first).utf8))
        #expect(decoded.outcome.exitCode == 0)
        let next = UsageCoordination(cacheURL: store.fileURL).refresh(runtime: runtime)
        #expect(next.outcome == .throttled && next.outcome.exitCode == 12)
        #expect(next.retryAt != nil && !next.freshSnapshot && !next.publicationAttempted)
        runtime.report(next)
        #expect(capture.output.last?.contains("Retry at Unix milliseconds:") == true)
        #expect(provider.count == 1)
    }

    @Test func concurrentRefreshFallbackHasOneFetchAndHonestThrottleResults() {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let provider = CoordinatedProvider()
        let runtime = runtime(provider, store)
        let results = CoordinationCapture()
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let result = UsageCoordination(cacheURL: store.fileURL).refresh(runtime: runtime, timeout: 2)
            results.append(result.outcome.rawValue)
        }
        #expect(results.output.filter { $0 == "refreshed" }.count == 1)
        #expect(results.output.filter { $0 == "throttled" }.count == 7)
        #expect(provider.count == 1)
    }

    @Test func fallbackCancellationAndShortDeadlineReachInFlightFetcher() throws {
        for cancel in [true, false] {
            let store = fixture()
            defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
            let stopped = CoordinationCapture()
            let provider = CancellableCoordinationProvider(onFetch: {
                if cancel {
                    stopped.append("stop")
                }
            })
            let runtime = UsageRuntime(
                fetcher: provider, store: store, notifier: CoordinationNotifier(), output: { _ in }
            )
            let start = UsageCoordination.time
            let result = UsageCoordination(cacheURL: store.fileURL).refresh(
                runtime: runtime, timeout: 0.03, cancelled: { !stopped.output.isEmpty }
            )
            #expect(result.outcome == (cancel ? .cancelled : .timeout))
            #expect(!result.freshSnapshot && !result.publicationAttempted)
            #expect(UsageCoordination.time - start < 0.3)
            #expect(try store.load().providers["codex"]?.snapshot == nil)
            #expect(try UsageCoordination(cacheURL: store.fileURL).acquire())
        }
    }

    @Test func runningCollectorDelegatesWithoutStartingFallbackProvider() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let server = UsageCoordination(cacheURL: store.fileURL)
        #expect(try server.acquire())
        try server.startServing()
        defer { server.close() }
        let ownerProvider = CoordinatedProvider()
        let ownerRuntime = runtime(ownerProvider, store)
        let fallback = CoordinatedProvider()
        let fallbackRuntime = runtime(fallback, store)
        let results = CoordinationCapture()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let result = UsageCoordination(cacheURL: store.fileURL).refresh(runtime: fallbackRuntime)
            results.append(result.outcome.rawValue)
            group.leave()
        }
        let deadline = UsageCoordination.time + 2
        while results.output.isEmpty, UsageCoordination.time < deadline {
            server.serve { ownerRuntime.dispatch($0) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(group.wait(timeout: .now() + 1) == .success)
        #expect(results.output == ["refreshed"])
        #expect(ownerProvider.count == 1 && fallback.count == 0)
        var info = stat()
        #expect(lstat(server.socketURL.path, &info) == 0)
        #expect(info.st_mode & 0o077 == 0)
    }

    @Test func coalescedRequestsReceiveActualResultAndNextBatchIsThrottled() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let server = UsageCoordination(cacheURL: store.fileURL)
        #expect(try server.acquire())
        try server.startServing()
        defer { server.close() }
        let provider = CoordinatedProvider()
        let runtime = runtime(provider, store)
        let request = try JSONEncoder().encode(UsagePrivateRequest())
        let clients = try (0 ..< 3).map { _ in try connect(server) }
        defer { clients.forEach { Darwin.close($0) } }
        for client in clients {
            #expect(UsageCoordination.sendFrame(client, data: request, deadline: UsageCoordination.time + 1,
                                                cancelled: { false }))
        }
        server.serve { runtime.dispatch($0) }
        for client in clients {
            var response = Data()
            #expect(UsageCoordination.readFrame(client, data: &response) == .complete)
            let result = try JSONDecoder().decode(UsageRefreshResult.self, from: response)
            #expect(result.outcome == .refreshed && result.publicationAttempted)
        }
        let next = try connect(server)
        defer { Darwin.close(next) }
        #expect(UsageCoordination.sendFrame(next, data: request, deadline: UsageCoordination.time + 1,
                                            cancelled: { false }))
        server.serve { runtime.dispatch($0) }
        var response = Data()
        #expect(UsageCoordination.readFrame(next, data: &response) == .complete)
        #expect(try JSONDecoder().decode(UsageRefreshResult.self, from: response).outcome == .throttled)
        #expect(provider.count == 1)
    }
}

extension UsageCoordinationTests {
    @Test func peerChecksRejectDifferentOwnerAndFramesAreBounded() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let server = UsageCoordination(cacheURL: store.fileURL)
        #expect(try server.acquire())
        try server.startServing()
        defer { server.close() }
        let client = try connect(server)
        defer { Darwin.close(client) }
        #expect(UsageCoordination.authorized(client))
        #expect(!UsageCoordination.authorized(client, owner: geteuid() + 1))
        #expect(!UsageCoordination.sendFrame(client, data: Data(repeating: 1, count: 4096),
                                             deadline: UsageCoordination.time + 1, cancelled: { false }))
        let provider = CoordinatedProvider()
        let runtime = runtime(provider, store)
        for payload in [Data("malformed\n".utf8), Data(repeating: 65, count: 4097),
                        Data(#"{"version":2,"operation":"refresh","provider":"codex"}"#.utf8) + Data([10]),
                        Data(#"{"version":1,"operation":"unknown","provider":"codex"}"#.utf8) + Data([10])] {
            let invalid = try connect(server)
            _ = payload.withUnsafeBytes { send(invalid, $0.baseAddress, payload.count, 0) }
            server.serve { runtime.dispatch($0) }
            Darwin.close(invalid)
        }
        #expect(provider.count == 0)
    }

    @Test func disconnectAndPartialRequestDoNotBlockOwnerAndWaitIsBounded() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let server = UsageCoordination(cacheURL: store.fileURL)
        #expect(try server.acquire())
        try server.startServing()
        defer { server.close() }
        let provider = CoordinatedProvider()
        let runtime = runtime(provider, store)
        let disconnected = try connect(server)
        #expect(try UsageCoordination.sendFrame(disconnected, data: JSONEncoder().encode(UsagePrivateRequest()),
                                                deadline: UsageCoordination.time + 1, cancelled: { false }))
        Darwin.close(disconnected)
        let partial = try connect(server)
        defer { Darwin.close(partial) }
        _ = send(partial, "{", 1, 0)
        server.serve { runtime.dispatch($0) }
        #expect(provider.count == 0)
        let start = UsageCoordination.time
        #expect(UsageCoordination(cacheURL: store.fileURL).refresh(runtime: runtime, timeout: 0.03).outcome == .timeout)
        #expect(UsageCoordination.time - start < 0.5)
        let cancelled = UsageCoordination(cacheURL: store.fileURL).refresh(runtime: runtime, cancelled: { true })
        #expect(cancelled.outcome == .cancelled)
        #expect(provider.count == 0)
        Thread.sleep(forTimeInterval: 2.01)
        server.serve { runtime.dispatch($0) }
        var buffer: UInt8 = 0
        #expect(recv(partial, &buffer, 1, 0) == 0)
        #expect(provider.count == 0)
    }

    @Test func watchDispatchSharesThePrimaryRuntimeAndReportsRedactedOutcomes() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let server = UsageCoordination(cacheURL: store.fileURL)
        #expect(try server.acquire())
        try server.startServing()
        defer { server.close() }
        let client = try connect(server)
        defer { Darwin.close(client) }
        let sent = try UsageCoordination.sendFrame(client, data: JSONEncoder().encode(UsagePrivateRequest()),
                                                   deadline: UsageCoordination.time + 1, cancelled: { false })
        #expect(sent)
        let provider = CoordinatedProvider()
        let capture = CoordinationCapture()
        var runtime = runtime(provider, store, capture: capture)
        let stopped = CoordinationCapture()
        runtime.isCancelled = { !stopped.output.isEmpty }
        runtime.watch(providers: [.codex], control: {
            server.serve { runtime.dispatch($0) }
        }, wait: { _ in stopped.append("stopped") })
        var response = Data()
        #expect(UsageCoordination.readFrame(client, data: &response) == .complete)
        #expect(try JSONDecoder().decode(UsageRefreshResult.self, from: response).outcome == .refreshed)
        #expect(provider.count == 1)
        for outcome in [UsageOutcome.collectorRunning, .coordinationUnavailable, .cancelled, .timeout] {
            runtime.report(UsageRefreshResult(provider: .codex, outcome: outcome, retryAt: nil,
                                              freshSnapshot: false, publicationAttempted: false), json: true)
            let output = try #require(capture.output.last)
            #expect(!output.contains(store.fileURL.path))
            let decoded = try JSONDecoder().decode(UsageRefreshResult.self, from: Data(output.utf8))
            #expect(decoded.outcome == outcome && decoded.outcome.exitCode != 0)
        }
    }

    @Test func staleEndpointRecoveryRequiresLockAndSymlinksAreRejected() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let first = UsageCoordination(cacheURL: store.fileURL)
        #expect(try first.acquire())
        // Create a stale socket, simulating a dead collector without owning listener cleanup.
        let socket = try UsageCoordination.makeSocket()
        #expect(try UsageCoordination.withAddress(first.socketURL.path) { bind(socket, $0, $1) } == 0)
        Darwin.close(socket)
        let second = UsageCoordination(cacheURL: store.fileURL)
        #expect(try !(second.acquire()))
        #expect(throws: UsageCoordinationError.self) { try second.startServing() }
        #expect(FileManager.default.fileExists(atPath: first.socketURL.path))
        first.close()
        #expect(try second.acquire())
        try second.startServing()
        second.close()
        #expect(!FileManager.default.fileExists(atPath: second.socketURL.path))
        try FileManager.default.createSymbolicLink(at: second.socketURL, withDestinationURL: store.fileURL)
        #expect(try second.acquire())
        #expect(throws: UsageCoordinationError.self) { try second.startServing() }
        second.close()
    }
}
