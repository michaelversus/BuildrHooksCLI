import ArgumentParser
@testable import BuildrHooksCLI
@testable import BuildrHooksCore
import Darwin
import Foundation
import Testing

struct ClaudeStatusLineRendererTests {
    @Test func earlyClosingDelegatesRetainCompleteCallback() throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "rate_limits": ["five_hour": ["used_percentage": 11]],
            "synthetic_padding": String(repeating: "x", count: 500_000)
        ])
        for command in ["printf static", "exec 0<&-; sleep 0.05; printf static",
                        "dd bs=1 count=1 of=/dev/null 2>/dev/null; exec 0<&-; printf static; exit 37"] {
            let fixture = try RenderFixture(payload)
            defer { fixture.close() }
            let result = try fixture.renderer.render(command: command)
            #expect(result.input == payload)
            #expect(result.exitCode == (command.contains("exit 37") ? 37 : 0))
            #expect(result.terminationSignal == nil)
            #expect(try Data(contentsOf: fixture.output) == Data("static".utf8))
        }
    }

    @Test func exactInputOutputErrorAndExitSurviveInvalidAndLargeCapture() throws {
        for data in [Data([0, 255, 10, 13, 65]), Data(repeating: 120, count: 2 * 1024 * 1024)] {
            let fixture = try RenderFixture(data)
            defer { fixture.close() }
            let result = try fixture.renderer
                .render(command: "/bin/cat; printf 'no-newline'; printf 'exact-error' >&2; exit 37")
            #expect(result.exitCode == 37 && result.terminationSignal == nil)
            #expect(try Data(contentsOf: fixture.output) == data + Data("no-newline".utf8))
            #expect(try Data(contentsOf: fixture.error) == Data("exact-error".utf8))
            #expect(result.input == (data.count <= ClaudeUsageParser.maximumBytes ? data : nil))
        }
    }

    @Test func defaultRenderingKeepsZeroAndAbsenceDistinctAndRejectsWholeMalformedReport() {
        #expect(ClaudeStatusLineRenderer
            .defaultLine(Data(#"{"rate_limits":{"five_hour":{"used_percentage":0}}}"#.utf8))
            == "Claude 5h: 100% remaining | weekly: unavailable")
        #expect(ClaudeStatusLineRenderer
            .defaultLine(Data(#"{"rate_limits":{"five_hour":{"used_percentage":2.5}}}"#.utf8))
            == "Claude 5h: 97.5% remaining | weekly: unavailable")
        #expect(ClaudeStatusLineRenderer
            .defaultLine(
                Data(#"{"rate_limits":{"five_hour":{"used_percentage":2},"seven_day":{"used_percentage":false}}}"#
                    .utf8)
            )
            == "Claude 5h: unavailable | weekly: unavailable")
        #expect(ClaudeStatusLineRenderer.defaultLine(nil) == "Claude 5h: unavailable | weekly: unavailable")
    }

    @Test func delegateExitsPromptlyEvenWhenStdinRemainsOpen() throws {
        let fixture = try RenderFixture(Data())
        defer { fixture.close() }
        let pipe = Pipe()
        defer { try? pipe.fileHandleForWriting.close(); try? pipe.fileHandleForReading.close() }
        var renderer = fixture.renderer
        renderer.input = pipe.fileHandleForReading
        let start = ProcessInfo.processInfo.systemUptime
        let result = try renderer.render(command: "exit 37")
        #expect(result.exitCode == 37)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test func exitedDelegateWithInheritedOpenReaderDoesNotBlockCapture() throws {
        let payload = Data(repeating: 32, count: 500_000)
        let fixture = try RenderFixture(payload)
        defer { fixture.close() }
        let start = ProcessInfo.processInfo.systemUptime
        let result = try fixture.renderer.render(command: "sleep 2 <&0 >/dev/null 2>&1 & printf static")
        #expect(result.input == payload && result.exitCode == 0)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }

    @Test func corruptUsageCacheCannotSuppressDelegateOrChangeItsExit() throws {
        let data = Data("exact callback\n".utf8)
        let fixture = try RenderFixture(data)
        defer { fixture.close() }
        let cache = fixture.directory.appendingPathComponent("corrupt-cache.json")
        try Data("corrupt".utf8).write(to: cache)
        let metadata = fixture.directory.appendingPathComponent("ownership.json")
        let original = try ClaudeStatusLineSettings.value([
            "type": "command", "command": "/bin/cat; printf exact-stderr >&2; exit 37"
        ])
        try JSONEncoder().encode(ClaudeStatusLineOwnership(
            original: original,
            installed: Data("null".utf8),
            runnerPath: "/unused"
        )).write(to: metadata)
        var command = try ClaudeStatusLineRunCommand.parse(["--metadata", metadata.path])
        command.makeSignals = { ClaudeStatusLineSignals(numbers: []) }
        command.makeRenderer = { _ in fixture.renderer }
        command.makeRuntime = {
            UsageRuntime(fetcher: CoordinatedProvider(), store: UsageFileStateStore(fileURL: cache),
                         notifier: CoordinationNotifier(), cliVersion: "1.2.8")
        }
        #expect(throws: ExitCode(37)) { try command.run() }
        #expect(try Data(contentsOf: fixture.output) == data)
        #expect(try Data(contentsOf: fixture.error) == Data("exact-stderr".utf8))
        #expect(try Data(contentsOf: cache) == Data("corrupt".utf8))
    }

    @Test func cancellationStopsOwnedDelegateGroupAndPreservesTermination() throws {
        let fixture = try RenderFixture(Data())
        defer { fixture.close() }
        var renderer = fixture.renderer
        let start = ProcessInfo.processInfo.systemUptime
        renderer.cancelled = { ProcessInfo.processInfo.systemUptime - start >= 0.1 ? SIGTERM : nil }
        let result = try renderer.render(command: "sleep 30")
        #expect(result.terminationSignal == SIGTERM)
        #expect(ProcessInfo.processInfo.systemUptime - start < 1)
    }
}

private struct RenderFixture {
    let directory: URL
    let output: URL
    let error: URL
    let renderer: ClaudeStatusLineRenderer
    init(_ data: Data) throws {
        directory = URL(fileURLWithPath: "/tmp")
            .appendingPathComponent("render-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let input = directory.appendingPathComponent("sanitized-fixture")
        output = directory.appendingPathComponent("output")
        error = directory.appendingPathComponent("error")
        try data.write(to: input)
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)
        renderer = try ClaudeStatusLineRenderer(input: FileHandle(forReadingFrom: input),
                                                output: FileHandle(forWritingTo: output),
                                                error: FileHandle(forWritingTo: error))
    }

    func close() {
        try? renderer.input.close(); try? renderer.output.close(); try? renderer.error.close()
        try? FileManager.default.removeItem(at: directory)
    }

    func command(runtime: UsageRuntime, cache: URL,
                 delegate: String = "exec 0<&-; printf static") throws -> ClaudeStatusLineRunCommand {
        let metadata = directory.appendingPathComponent("run-ownership.json")
        try JSONEncoder().encode(ClaudeStatusLineOwnership(
            original: ClaudeStatusLineSettings.value(["type": "command", "command": delegate]),
            installed: Data("null".utf8), runnerPath: "/unused"
        )).write(to: metadata)
        var command = try ClaudeStatusLineRunCommand.parse(["--metadata", metadata.path])
        command.makeSignals = { ClaudeStatusLineSignals(numbers: []) }
        command.makeRenderer = { _ in renderer }
        command.makeRuntime = { runtime }
        command.makeCoordination = { UsageCoordination(cacheURL: cache) }
        return command
    }
}

extension ClaudeStatusLineRendererTests {
    @Test func validQuotaIsAcceptedEvenWhenDelegateReturnsNonzero() throws {
        let fixture = try RenderFixture(Data(#"{"rate_limits":{"five_hour":{"used_percentage":11}}}"#.utf8))
        defer { fixture.close() }
        let store = UsageFileStateStore(fileURL: fixture.directory.appendingPathComponent("state.json"))
        let runtime = UsageRuntime(fetcher: CoordinatedProvider(), store: store,
                                   notifier: CoordinationNotifier(), cliVersion: "1.2.9")
        let command = try fixture.command(runtime: runtime, cache: store.fileURL,
                                          delegate: "exec 0<&-; printf static; exit 37")
        #expect(throws: ExitCode(37)) { try command.run() }
        #expect(try store.load().providers["claude"]?.snapshot?.windows.first?.usedPercent == 11)
        #expect(try Data(contentsOf: fixture.output) == Data("static".utf8))
    }

    @Test func earlyClosingRunnerAcceptsQuotaAndAbsenceButRetainsOnMalformedOrOversizedInput() throws {
        let seed = Data(#"""
        {"rate_limits":{"five_hour":{"used_percentage":70},"seven_day":{"used_percentage":80}}}
        """#.utf8)
        for report in [#"{"rate_limits":{"five_hour":{"used_percentage":11}}}"#, "{}", "malformed",
                       "{}" + String(repeating: " ", count: ClaudeUsageParser.maximumBytes)] {
            let payload = Data((report + String(repeating: " ", count: 500_000)).utf8)
            let fixture = try RenderFixture(payload)
            defer { fixture.close() }
            let store = UsageFileStateStore(fileURL: fixture.directory.appendingPathComponent("state.json"))
            let runtime = UsageRuntime(fetcher: CoordinatedProvider(), store: store,
                                       notifier: CoordinationNotifier(), cliVersion: "1.2.9")
            let coordination = UsageCoordination(cacheURL: store.fileURL)
            _ = coordination.captureClaude(runtime: runtime) { seed }
            let prior = try #require(store.load().providers["claude"]?.snapshot)
            try fixture.command(runtime: runtime, cache: store.fileURL).run()
            let state = try #require(store.load().providers["claude"])
            if report.hasPrefix("{\"rate_limits") {
                #expect(state.snapshot?.windows.count == 1)
                #expect(state.snapshot?.windows.first?.usedPercent == 11)
            } else if report == "{}" {
                #expect(state.snapshot == nil && state.latestInvalidationRevision > prior.revision)
            } else {
                #expect(state.snapshot == prior && state.status?.status == .temporaryFailure)
            }
            #expect(try Data(contentsOf: fixture.output) == Data("static".utf8))
        }
    }

    @Test func clearDuringRunnerRenderingFencesCapturedInputAndNewCallbackRemainsEligible() throws {
        let payload = Data(#"{"rate_limits":{"five_hour":{"used_percentage":11}}}"#.utf8)
        let fixture = try RenderFixture(payload)
        defer { fixture.close() }
        let store = UsageFileStateStore(fileURL: fixture.directory.appendingPathComponent("state.json"))
        let runtime = UsageRuntime(fetcher: CoordinatedProvider(), store: store,
                                   notifier: CoordinationNotifier(), cliVersion: "1.2.9")
        let coordination = UsageCoordination(cacheURL: store.fileURL)
        var command = try fixture.command(runtime: runtime, cache: store.fileURL)
        command.makeRenderer = { _ in
            #expect(coordination.clear(runtime: runtime, provider: .claude).localCleared)
            return fixture.renderer
        }
        try command.run()
        #expect(try store.load().providers["claude"]?.snapshot == nil)
        #expect(coordination.captureClaude(runtime: runtime) { payload }.outcome == .refreshed)
    }
}
