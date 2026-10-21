import ArgumentParser
@testable import BuildrHooksCLI
import BuildrHooksCore
import Darwin
import Foundation
import Testing

struct ClaudeStatusLineRendererTests {
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
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
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
}
