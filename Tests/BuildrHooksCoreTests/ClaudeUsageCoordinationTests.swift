@testable import BuildrHooksCore
import Darwin
import Foundation
import Testing

extension UsageCoordinationTests {
    @Test func activeCodexOwnerAcceptsDistinctClaudeCallbacksAndProviderClearBoundaries() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let provider = CoordinatedProvider()
        let capture = CoordinationCapture()
        let runtime = UsageRuntime(fetcher: provider, store: store,
                                   notifier: ClaudeCoordinationNotifier(capture: capture), cliVersion: "1.2.8")
        #expect(UsageCoordination(cacheURL: store.fileURL).refresh(runtime: runtime).outcome == .refreshed)
        let codex = try #require(store.load().providers["codex"]?.snapshot)
        let server = UsageCoordination(cacheURL: store.fileURL)
        #expect(try server.acquire())
        try server.startServing()
        defer { server.close() }
        let primary = UsageWindow(limitCode: "claude", role: "primary", usedPercent: 0, durationMinutes: 300)
        let secondary = UsageWindow(limitCode: "claude", role: "secondary", usedPercent: 12.5, durationMinutes: 10080)
        let requests = [UsagePrivateRequest(windows: [primary], generation: 0),
                        UsagePrivateRequest(windows: [secondary], generation: 0),
                        UsagePrivateRequest(operation: .clear, provider: .codex),
                        UsagePrivateRequest(operation: .clear, provider: .claude),
                        UsagePrivateRequest(windows: [primary], generation: 0)]
        var clients: [Int32] = []
        defer { clients.forEach { Darwin.close($0) } }
        for request in requests {
            let client = try connect(server)
            clients.append(client)
            #expect(try UsageCoordination.sendFrame(client, data: JSONEncoder().encode(request),
                                                    deadline: UsageCoordination.time + 1, cancelled: { false }))
        }
        server.serve { runtime.dispatch($0) }
        let outcomes = try clients.map { client in
            var data = Data()
            #expect(UsageCoordination.readFrame(client, data: &data) == .complete)
            return try JSONDecoder().decode(UsageRefreshResult.self, from: data).outcome
        }
        #expect(outcomes == [.refreshed, .refreshed, .cleared, .cleared, .invalidated])
        let now = Date()
        let snapshots = capture.output.compactMap { try? UsageWire().decodeSnapshot($0, now: now) }
        #expect(snapshots.filter { $0.provider == .claude }.map(\.windows) == [[primary], [secondary]])
        #expect(snapshots.first?.windows == codex.windows && snapshots.first?.timestamp == codex.timestamp)
        #expect(snapshots.first?.revision == codex.revision)
        #expect(provider.count == 1)
        #expect(try store.load().providers["claude"]?.snapshot == nil)
        #expect(try store.load().providers["codex"]?.snapshot == nil)
    }

    @Test func captureRoutesToExistingOwnerWithoutFallbackFetchAndPublishesCommittedOrder() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let server = UsageCoordination(cacheURL: store.fileURL)
        #expect(try server.acquire())
        try server.startServing()
        defer { server.close() }
        let provider = CoordinatedProvider()
        let runtime = UsageRuntime(fetcher: provider, store: store, notifier: CoordinationNotifier(),
                                   cliVersion: "1.2.8")
        let output = CoordinationCapture()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            // Synthetic configuration roots carry no identity and share the same owner.
            for input in [#"{"cwd":"/synthetic/root-one","rate_limits":{"five_hour":{"used_percentage":1}}}"#,
                          #"{"cwd":"/synthetic/root-two","rate_limits":{"seven_day":{"used_percentage":2}}}"#] {
                let result = UsageCoordination(cacheURL: store.fileURL).captureClaude(runtime: runtime) {
                    Data(input.utf8)
                }
                output.append(result.provider.rawValue + ":" + result.outcome.rawValue)
            }
            group.leave()
        }
        let deadline = UsageCoordination.time + 3
        while output.output.count < 2, UsageCoordination.time < deadline {
            server.serve { runtime.dispatch($0) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(group.wait(timeout: .now() + 1) == .success)
        #expect(output.output == ["claude:refreshed", "claude:refreshed"])
        #expect(provider.count == 0)
        let state = try #require(store.load().providers["claude"])
        #expect(state.snapshot?.windows.first?.role == "secondary" && state.snapshot?.windows.count == 1)
        #expect(state.snapshot?.revision == 3 && state.status?.revision == 4)
        let bytes = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!bytes.contains("synthetic") && !bytes.contains("cwd"))
    }

    @Test func clearDuringInputRejectsPendingCaptureAndLaterCallbackSucceeds() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let provider = CoordinatedProvider()
        let runtime = UsageRuntime(fetcher: provider, store: store, notifier: CoordinationNotifier(),
                                   cliVersion: "1.2.8")
        let input = Data(#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#.utf8)
        let old = UsageCoordination(cacheURL: store.fileURL).captureClaude(runtime: runtime) {
            #expect(UsageCoordination(cacheURL: store.fileURL).clear(runtime: runtime, provider: .claude).localCleared)
            return input
        }
        #expect(old.outcome == .invalidated && !old.publicationAttempted)
        #expect(try store.load().providers["claude"]?.snapshot == nil)
        let fresh = UsageCoordination(cacheURL: store.fileURL).captureClaude(runtime: runtime) { input }
        #expect(fresh.outcome == .refreshed)
        #expect(provider.count == 0)
    }

    @Test func noResponderDoesNotCreateServiceAndCancellationDoesNotAccept() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let coordination = UsageCoordination(cacheURL: store.fileURL)
        #expect(!coordination.available(timeout: 0.01))
        #expect(!FileManager.default.fileExists(atPath: coordination.socketURL.path))
        let provider = CoordinatedProvider()
        var runtime = UsageRuntime(fetcher: provider, store: store, notifier: CoordinationNotifier(),
                                   cliVersion: "1.2.8")
        runtime.isCancelled = { true }
        let result = coordination.captureClaude(runtime: runtime) { Data("{}".utf8) }
        #expect(result.outcome == .cancelled && !result.publicationAttempted)
        #expect(try store.load().providers.isEmpty)
        #expect(provider.count == 0)
    }
}

private struct ClaudeCoordinationNotifier: UsageNotifying {
    let capture: CoordinationCapture
    func post(name _: String, payload: String) {
        capture.append(payload)
    }
}

extension UsageCoordinationTests {
    @Test func delayedPublicationRetainsOwnershipUntilConcurrentClearCanCommit() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let notifier = DelayedClaudeNotifier(store: store)
        let provider = CoordinatedProvider()
        let runtime = UsageRuntime(fetcher: provider, store: store, notifier: notifier, cliVersion: "1.2.8")
        let captureFinished = DispatchSemaphore(value: 0)
        let clearFinished = DispatchSemaphore(value: 0)
        let output = CoordinationCapture()
        DispatchQueue.global().async {
            let result = UsageCoordination(cacheURL: store.fileURL).captureClaude(runtime: runtime, timeout: 3) {
                Data(#"{"rate_limits":{"five_hour":{"used_percentage":1}}}"#.utf8)
            }
            output.append(result.outcome.rawValue)
            captureFinished.signal()
        }
        #expect(notifier.entered.wait(timeout: .now() + 2) == .success)
        DispatchQueue.global().async {
            let result = UsageCoordination(cacheURL: store.fileURL)
                .clear(runtime: runtime, provider: .claude, timeout: 3)
            output.append(result.outcome.rawValue)
            clearFinished.signal()
        }
        #expect(clearFinished.wait(timeout: .now() + 0.05) == .timedOut)
        #expect(try store.load().providers["claude"]?.snapshot != nil)
        notifier.release.signal()
        #expect(captureFinished.wait(timeout: .now() + 2) == .success)
        #expect(clearFinished.wait(timeout: .now() + 2) == .success)
        #expect(Set(output.output) == Set(["refreshed", "cleared"]))
        #expect(try store.load().providers["claude"]?.snapshot == nil)
        #expect(notifier.messages.output.count == 3)
        let now = Date()
        let initial = try UsageWire().decodeSnapshot(notifier.messages.output[0], now: now)
        let accepted = try UsageWire().decodeStatus(notifier.messages.output[1], now: now)
        let cleared = try UsageWire().decodeStatus(notifier.messages.output[2], now: now)
        #expect(accepted.retainedSnapshotRevision == initial.revision)
        #expect(cleared.latestInvalidationRevision > accepted.revision && cleared.retainedSnapshotRevision == nil)
    }
}

private final class DelayedClaudeNotifier: UsageNotifying, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    let messages = CoordinationCapture()
    let store: UsageFileStateStore
    init(store: UsageFileStateStore) {
        self.store = store
    }

    func post(name: String, payload: String) throws {
        if name == UsageRuntime.snapshotNotification {
            let published = try UsageWire().decodeSnapshot(payload, now: Date())
            #expect(try store.load().providers["claude"]?.snapshot?.revision == published.revision)
            entered.signal()
            #expect(release.wait(timeout: .now() + 2) == .success)
        }
        messages.append(payload)
    }
}

extension UsageCoordinationTests {
    @Test func malformedOrOversizedCallbackRetainsWholePriorReportAndNeverStoresRawInput() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let provider = CoordinatedProvider()
        let runtime = UsageRuntime(fetcher: provider, store: store, notifier: CoordinationNotifier(),
                                   cliVersion: "1.2.8")
        #expect(UsageCoordination(cacheURL: store.fileURL).captureClaude(runtime: runtime) {
            Data(#"{"rate_limits":{"five_hour":{"used_percentage":1},"seven_day":{"used_percentage":2}}}"#.utf8)
        }.outcome == .refreshed)
        let retained = try #require(store.load().providers["claude"]?.snapshot)
        for input in [#"""
        {"private":"never-retain-this","rate_limits":{"five_hour":{"used_percentage":8},
        "seven_day":{"used_percentage":false}}}
        """#, "{}" + String(repeating: " ", count: ClaudeUsageParser.maximumBytes)] {
            #expect(UsageCoordination(cacheURL: store.fileURL).captureClaude(runtime: runtime) {
                Data(input.utf8)
            }.outcome == .temporaryFailure)
            let state = try #require(store.load().providers["claude"])
            #expect(state.snapshot == retained && state.status?.retainedSnapshotRevision == retained.revision)
            #expect(state.status?.status == .temporaryFailure && state.status?.receivedAt == retained.receivedAt)
        }
        let persisted = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(!persisted.contains("never-retain-this") && !persisted.contains("private"))
        #expect(provider.count == 0)
    }
}
