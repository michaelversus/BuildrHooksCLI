@testable import BuildrHooksCLI
import Foundation
import Testing

struct ClaudeStatusLineInstalledTests {
    @Test func installedStandaloneRunnerSurvivesMainHelperRemovalWithExactShellContext() throws {
        let fixture = try StatusLineFixture()
        defer { fixture.close() }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let built = package.appendingPathComponent(".build/debug/BuildrHooksCLI")
        try Data(contentsOf: built).write(to: fixture.executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: fixture.executable.path
        )
        let linked = fixture.root.appendingPathComponent("brew symlink")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: fixture.executable)
        let original = "/bin/cat; printf '%s' \"$PWD|$BUILDRHOOKS_FIXTURE\"; printf 'exact-error' >&2; exit 37"
        try fixture.write(["statusLine": ["type": "command", "command": original,
                                          "unknown": ["preserved": true]]])
        _ = try fixture.settings.setup(apply: true, repair: false, executable: linked)
        let installed = try #require(try fixture.settings.read().object["statusLine"] as? [String: Any])
        let command = try #require(installed["command"] as? String)
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.removeItem(at: fixture.executable)
        // Capture fails before publication in this temporary home: no real state or notifications.
        let cache = fixture.root.appendingPathComponent(".codex/buildr-artifacts/account-usage.json")
        try FileManager.default.createDirectory(
            at: cache.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("synthetic-corrupt-cache".utf8).write(to: cache)
        let shell = InstalledLineShell(root: fixture.root)
        let direct = try shell.run(original, name: "direct")
        let wrapped = try shell.run(command, name: "wrapped")
        #expect(direct.code == 37 && wrapped.code == direct.code)
        #expect(direct.reason == .exit && wrapped.reason == direct.reason)
        #expect(wrapped.output == direct.output && wrapped.error == direct.error)
        let output = try #require(String(bytes: direct.output, encoding: .utf8))
        #expect(output.hasPrefix("sanitized callback\n") && output.contains(fixture.root.lastPathComponent))
        #expect(output.hasSuffix("|context ' with spaces"))
        #expect(try Data(contentsOf: cache) == Data("synthetic-corrupt-cache".utf8))
    }
}

private struct InstalledLineResult {
    let code: Int32
    let reason: Process.TerminationReason
    let output: Data
    let error: Data
}

private struct InstalledLineShell {
    let root: URL
    func run(_ command: String, name: String) throws -> InstalledLineResult {
        let output = root.appendingPathComponent(name + "-stdout")
        let error = root.appendingPathComponent(name + "-stderr")
        FileManager.default.createFile(atPath: output.path, contents: nil)
        FileManager.default.createFile(atPath: error.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: output)
        let stderr = try FileHandle(forWritingTo: error)
        defer { try? stdout.close(); try? stderr.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = root
        var environment = ProcessInfo.processInfo.environment
        environment["CFFIXED_USER_HOME"] = root.path
        environment["HOME"] = root.path
        environment["BUILDRHOOKS_FIXTURE"] = "context ' with spaces"
        process.environment = environment
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("sanitized callback\n".utf8))
        try input.fileHandleForWriting.close()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            process.terminate()
        }
        process.waitUntilExit()
        return try InstalledLineResult(code: process.terminationStatus, reason: process.terminationReason,
                                       output: Data(contentsOf: output), error: Data(contentsOf: error))
    }
}
