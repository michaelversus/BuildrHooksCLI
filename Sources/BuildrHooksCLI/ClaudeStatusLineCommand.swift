import ArgumentParser
import BuildrHooksCore
import Darwin
import Foundation

struct ClaudeStatusLineCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "statusline", abstract: "Explicit, reversible Claude reported-usage integration.",
        discussion: ClaudeStatusLineSettings.disclosure,
        subcommands: [ClaudeStatusLineSetupCommand.self, ClaudeStatusLineRemoveCommand.self,
                      ClaudeStatusLineStatusCommand.self, ClaudeStatusLineCaptureCommand.self,
                      ClaudeStatusLineRunCommand.self]
    )
}

struct ClaudeStatusLineScope: ParsableArguments {
    @Option(
        name: .long,
        help: "Selected user configuration root; defaults to CLAUDE_CONFIG_DIR or ~/.claude."
    )
    var configDir: String?
    @Option(name: .long, help: "Explicit project directory; targets its .claude/settings.local.json.")
    var project: String?
    func validate() throws {
        if configDir != nil, project != nil {
            throw ValidationError("Choose --config-dir or --project, not both.")
        }
    }

    var settings: ClaudeStatusLineSettings {
        let root = ClaudeStatusLineSettings.selectedRoot(configDirectory: configDir, project: project)
        let managed = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")
        let fragments = (try? FileManager.default.contentsOfDirectory(
            at: managed.appendingPathComponent("managed-settings.d"), includingPropertiesForKeys: nil
        ))?.filter { $0.pathExtension == "json" } ?? []
        return ClaudeStatusLineSettings(root: root, project: project != nil, managedURLs:
            [
                managed.appendingPathComponent("managed-settings.json"),
                root.appendingPathComponent("managed-settings.json")
            ]
                + fragments)
    }
}

struct ClaudeStatusLineSetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Preview preservation/default footer change; --apply installs explicitly."
    )
    @OptionGroup var scope: ClaudeStatusLineScope
    @Flag(name: .long, help: "Apply the displayed setup after reviewing its preview.") var apply = false
    @Flag(
        name: .long,
        help: "Explicitly adopt a replacement delegate; preview first, then repeat with --apply."
    )
    var repair = false
    func run() throws {
        guard let executable = Bundle.main.executableURL else { throw ClaudeStatusLineError.unsafePath }
        try print(scope.settings.setup(apply: apply, repair: repair, executable: executable))
    }
}

struct ClaudeStatusLineRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Preview restoration; --apply restores only a still-owned statusLine."
    )
    @OptionGroup var scope: ClaudeStatusLineScope
    @Flag(
        name: .long,
        help: "Restore the prior value/absence while preserving unrelated/later settings."
    ) var apply = false
    func run() throws {
        try print(scope.settings.remove(apply: apply))
    }
}

struct ClaudeStatusLineStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Describe setup ownership; it does not prove session use or received quota."
    )
    @OptionGroup var scope: ClaudeStatusLineScope
    func run() throws {
        try print(scope.settings.installationStatus())
    }
}

struct ClaudeStatusLineCaptureCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capture", abstract: "Accept bounded normalized quota stdin locally; no network quota fetch.",
        discussion: "Last received means bridge acceptance time. Publication is attempted, never acknowledged."
    )
    @Flag(name: .long, help: "Emit the local outcome as JSON.") var json = false
    enum CodingKeys: String, CodingKey { case json }
    var makeRuntime: () -> UsageRuntime = { UsageRuntime(fetcher: CodexUsageFetcher(), cliVersion: version) }
    var makeCoordination: () -> UsageCoordination = { UsageCoordination() }
    var makeSignals: () -> ClaudeStatusLineSignals = { ClaudeStatusLineSignals() }
    var readInput: (ClaudeStatusLineSignals) throws -> Data? = { signals in
        try ClaudeStatusLineRenderer(cancelled: { signals.received }).readCallback()
    }

    func run() throws {
        let signals = makeSignals()
        defer { signals.close() }
        var runtime = makeRuntime()
        runtime.isCancelled = { signals.received != nil }
        let result = makeCoordination().captureClaude(runtime: runtime) {
            guard let data = try readInput(signals) else {
                throw UsageWireError.invalidPayload
            }
            return data
        }
        runtime.report(result, json: json)
        if result.outcome.exitCode != 0 {
            throw ExitCode(result.outcome.exitCode)
        }
    }
}

struct ClaudeStatusLineRunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "Run a setup-owned status line with transparent delegate output."
    )
    @Option(name: .long, help: "Private immutable ownership record created by setup.") var metadata: String
    enum CodingKeys: String, CodingKey { case metadata }
    var makeRuntime: () -> UsageRuntime = { UsageRuntime(fetcher: CodexUsageFetcher(), cliVersion: version) }
    var makeCoordination: () -> UsageCoordination = { UsageCoordination() }
    var makeSignals: () -> ClaudeStatusLineSignals = { ClaudeStatusLineSignals() }
    var makeRenderer: (ClaudeStatusLineSignals) -> ClaudeStatusLineRenderer = { signals in
        ClaudeStatusLineRenderer(cancelled: { signals.received })
    }

    func run() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: metadata))
        guard bytes.count <= 4 * 1024 * 1024 else { throw ClaudeStatusLineError.invalidSettings }
        let record = try JSONDecoder().decode(ClaudeStatusLineOwnership.self, from: bytes)
        let command = try ClaudeStatusLineSettings.command(record.original)
        let signals = makeSignals()
        defer { signals.close() }
        var runtime = makeRuntime()
        runtime.isCancelled = { signals.received != nil }
        // Capture failure, including a corrupt/unavailable cache, never suppresses rendering.
        let generation = try? runtime.claudeCaptureGeneration()
        let rendered = try makeRenderer(signals).render(command: command)
        if let generation, signals.received == nil, rendered.terminationSignal == nil {
            let windows = rendered.input.flatMap { try? ClaudeUsageParser().windows(from: $0) }
            _ = makeCoordination().refresh(runtime: runtime, timeout: 2, cancelled: runtime.isCancelled,
                                           request: UsagePrivateRequest(
                                               windows: windows,
                                               generation: generation
                                           ))
        }
        signals.close()
        if let termination = rendered.terminationSignal {
            signal(termination, SIG_DFL)
            raise(termination)
        }
        if rendered.exitCode != 0 {
            throw ExitCode(rendered.exitCode)
        }
    }
}
