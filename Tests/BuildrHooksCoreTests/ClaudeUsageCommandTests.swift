import ArgumentParser
@testable import BuildrHooksCLI
@testable import BuildrHooksCore
import Foundation
import Testing

struct ClaudeUsageCommandTests {
    @Test func lifecyclePreservesDistinctCorrelatedRequestsAndRejectsUnboundedOrExtraFields() throws {
        let center = NotificationCenter()
        let lifecycle = UsageWatchLifecycle(signalNumbers: [], recoveryCenter: center, wakeCenter: NotificationCenter())
        defer { lifecycle.close() }
        let name = Notification.Name(UsageRuntime.requestNotification)
        for id in ["old", "old", "current"] {
            try center.post(name: name, object: nil, userInfo: UsageReplayRequest(replayRequestID: id).userInfo)
        }
        center.post(name: name, object: nil, userInfo: ["replayRequestID": "current", "extra": "invalid"])
        center.post(name: name, object: nil, userInfo: ["replayRequestID": String(repeating: "a", count: 129)])
        #expect(lifecycle.takeTriggers() == [.claudeRecoveryRequested("old"), .claudeRecoveryRequested("current")])
        #expect(lifecycle.takeTriggers().isEmpty)
    }

    @Test func explicitClaudeClearCommandDoesNotReadProviderAndKeepsCodex() throws {
        let store = UsageFileStateStore(fileURL: URL(fileURLWithPath: "/tmp/cc-\(UUID().uuidString)/state.json"))
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let provider = CoordinatedProvider()
        let output = CoordinationCapture()
        let runtime = UsageRuntime(fetcher: provider, store: store, notifier: CoordinationNotifier(),
                                   cliVersion: "1.2.8",
                                   output: { output.append($0) })
        _ = UsageCoordination(cacheURL: store.fileURL).refresh(runtime: runtime)
        let codex = try #require(store.load().providers["codex"]?.snapshot)
        var command = try UsageClearCommand.parse(["--provider", "claude", "--json"])
        command.makeExecution = { _ in
            UsageCommandExecution(runtime: runtime, coordination: UsageCoordination(cacheURL: store.fileURL))
        }
        try command.run()
        let result = try JSONDecoder().decode(UsageRefreshResult.self, from: Data(#require(output.output.last).utf8))
        #expect(result.provider == .claude && result.localCleared && result.publicationAttempted)
        #expect(try store.load().providers["codex"]?.snapshot == codex)
        #expect(provider.count == 1)
    }
}
