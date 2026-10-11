import AppKit
import ArgumentParser
@testable import BuildrHooksCLI
@testable import BuildrHooksCore
import Foundation
import Testing

struct UsageCommandExecutionTests {
    private struct Fixture {
        let store: UsageFileStateStore
        let provider: CoordinatedProvider
        let output: CoordinationCapture
        let execution: UsageCommandExecution
    }

    private func fixture() -> Fixture {
        let store = UsageFileStateStore(fileURL: URL(fileURLWithPath: "/tmp/c-\(UUID().uuidString)/state.json"))
        let provider = CoordinatedProvider()
        let output = CoordinationCapture()
        let runtime = UsageRuntime(fetcher: provider, store: store, notifier: CoordinationNotifier(),
                                   output: { output.append($0) })
        return Fixture(store: store, provider: provider, output: output, execution: UsageCommandExecution(
            runtime: runtime, coordination: UsageCoordination(cacheURL: store.fileURL)
        ))
    }

    @Test func lifecycleCoalescesWakeAndRecoveryRejectsPayloadsAndRemovesObservers() {
        let recovery = NotificationCenter()
        let wake = NotificationCenter()
        let lifecycle = UsageWatchLifecycle(signalNumbers: [], recoveryCenter: recovery, wakeCenter: wake)
        let request = Notification.Name(UsageRuntime.requestNotification)
        recovery.post(name: request, object: nil, userInfo: ["unexpected": "payload"])
        #expect(lifecycle.takeTriggers().isEmpty && !lifecycle.cancelled)
        for _ in 0 ..< 3 {
            wake.post(name: NSWorkspace.didWakeNotification, object: nil)
            recovery.post(name: request, object: nil)
        }
        #expect(lifecycle.takeTriggers() == [.wake, .recoveryRequested])
        #expect(lifecycle.takeTriggers().isEmpty)
        lifecycle.close()
        wake.post(name: NSWorkspace.didWakeNotification, object: nil)
        recovery.post(name: request, object: nil)
        #expect(lifecycle.takeTriggers().isEmpty)
    }

    @Test func refreshPersistsAndReportsThenReturnsThrottleExitCode() throws {
        let fixture = fixture()
        let store = fixture.store
        let provider = fixture.provider
        let output = fixture.output
        let execution = fixture.execution
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var command = try UsageRefreshCommand.parse(["--provider", "codex", "--json", "--codex-path", "/fixture"])
        command.makeExecution = { path in
            #expect(path == "/fixture")
            return execution
        }
        try command.run()
        let first = try JSONDecoder().decode(UsageRefreshResult.self, from: Data(#require(output.output.first).utf8))
        #expect(first.outcome == .refreshed && first.freshSnapshot)
        #expect(try store.load().providers["codex"]?.snapshot != nil)
        #expect(throws: ExitCode(12)) { try command.run() }
        let last = try JSONDecoder().decode(UsageRefreshResult.self, from: Data(#require(output.output.last).utf8))
        #expect(last.outcome == .throttled && last.retryAt != nil && !last.publicationAttempted)
        #expect(provider.count == 1)
    }

    @Test func clearRemovesSnapshotAndPublishesInvalidationWithoutFetching() throws {
        let fixture = fixture()
        let store = fixture.store
        let provider = fixture.provider
        let output = fixture.output
        let execution = fixture.execution
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        _ = execution.runtime.refresh()
        let previous = try #require(store.load().providers["codex"]?.revision)
        var command = try UsageClearCommand.parse(["--provider", "codex", "--json"])
        command.makeExecution = { _ in execution }
        try command.run()
        let result = try JSONDecoder().decode(UsageRefreshResult.self, from: Data(#require(output.output.last).utf8))
        #expect(result.outcome == .cleared && result.localCleared && !result.freshSnapshot)
        let saved = try #require(store.load().providers["codex"])
        #expect(saved.snapshot == nil && saved.latestInvalidationRevision > previous)
        #expect(provider.count == 1)
    }

    @Test func watchRejectsExistingOwnerWithoutFetching() throws {
        let fixture = fixture()
        let store = fixture.store
        let provider = fixture.provider
        let output = fixture.output
        let execution = fixture.execution
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let owner = UsageCoordination(cacheURL: store.fileURL)
        defer { owner.close() }
        #expect(try owner.acquire())
        var command = try UsageWatchCommand.parse(["--provider", "codex", "--json"])
        command.makeExecution = { _ in execution }
        #expect(throws: ExitCode(20)) { try command.run() }
        let result = try JSONDecoder().decode(UsageRefreshResult.self, from: Data(#require(output.output.last).utf8))
        #expect(result.outcome == .collectorRunning && !result.publicationAttempted)
        #expect(provider.count == 0)
        #expect(try !UsageCoordination(cacheURL: store.fileURL).acquire())
    }

    @Test func watchCancellationReleasesSocketAndLock() throws {
        let fixture = fixture()
        let store = fixture.store
        let provider = fixture.provider
        let original = fixture.execution
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        var execution = original
        execution.runtime.isCancelled = { true }
        var command = try UsageWatchCommand.parse(["--provider", "codex"])
        command.makeExecution = { _ in execution }
        try command.run()
        #expect(provider.count == 0)
        #expect(!FileManager.default.fileExists(atPath: execution.coordination.socketURL.path))
        let next = UsageCoordination(cacheURL: store.fileURL)
        defer { next.close() }
        #expect(try next.acquire())
    }

    @Test func unavailableCoordinationReportsFailureForAllCommands() throws {
        let fixture = fixture()
        let store = fixture.store
        let provider = fixture.provider
        let output = fixture.output
        let execution = fixture.execution
        let directory = store.fileURL.deletingLastPathComponent()
        try Data("blocked".utf8).write(to: directory)
        defer { try? FileManager.default.removeItem(at: directory) }
        var refresh = try UsageRefreshCommand.parse(["--provider", "codex", "--json"])
        refresh.makeExecution = { _ in execution }
        #expect(throws: ExitCode(21)) { try refresh.run() }
        var clear = try UsageClearCommand.parse(["--provider", "codex", "--json"])
        clear.makeExecution = { _ in execution }
        #expect(throws: ExitCode(21)) { try clear.run() }
        var watch = try UsageWatchCommand.parse(["--provider", "codex", "--json"])
        watch.makeExecution = { _ in execution }
        #expect(throws: ExitCode(21)) { try watch.run() }
        for line in output.output {
            let result = try JSONDecoder().decode(UsageRefreshResult.self, from: Data(line.utf8))
            #expect(result.outcome == .coordinationUnavailable && !result.publicationAttempted)
        }
        #expect(output.output.count == 3 && provider.count == 0)
    }
}
