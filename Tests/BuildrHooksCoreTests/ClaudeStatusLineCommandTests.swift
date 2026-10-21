import ArgumentParser
@testable import BuildrHooksCLI
import BuildrHooksCore
import Foundation
import Testing

struct ClaudeStatusLineCommandTests {
    @Test func setupPreviewCommandIsAvailableWithoutApplying() throws {
        let command = try BuildrHooksCLICommand.parseAsRoot(["claude", "statusline", "setup"])
        #expect(String(describing: type(of: command)) == "ClaudeStatusLineSetupCommand")
    }

    @Test func captureCommandIsAvailableSeparatelyFromRendering() throws {
        let command = try BuildrHooksCLICommand.parseAsRoot(["claude", "statusline", "capture"])
        #expect(String(describing: type(of: command)) == "ClaudeStatusLineCaptureCommand")
    }
}

extension ClaudeStatusLineCommandTests {
    @Test func captureAcceptsCurrentCallbackThroughExistingCoordinationAndReportsAttemptOnly() throws {
        let fixture = try StatusLineFixture()
        defer { fixture.close() }
        let store = UsageFileStateStore(fileURL: fixture.root.appendingPathComponent("usage.json"))
        let output = CoordinationCapture()
        let runtime = UsageRuntime(fetcher: CoordinatedProvider(), store: store,
                                   notifier: CoordinationNotifier(), cliVersion: "1.2.8",
                                   output: { output.append($0) })
        var command = try ClaudeStatusLineCaptureCommand.parse(["--json"])
        command.makeRuntime = { runtime }
        command.makeCoordination = { UsageCoordination(cacheURL: store.fileURL) }
        command.makeSignals = { ClaudeStatusLineSignals(numbers: []) }
        command.readInput = { _ in Data(#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#.utf8) }
        try command.run()
        let state = try #require(try store.load().providers["claude"])
        #expect(state.snapshot?.windows.first?.usedPercent == 0)
        #expect(state.snapshot?.receivedAt != nil && state.snapshot?.collectedAt == nil)
        let payload = try #require(output.output.first)
        let result = try JSONDecoder().decode(UsageRefreshResult.self, from: Data(payload.utf8))
        #expect(result.provider == .claude && result.publicationAttempted && !result.localCleared)
    }
}
