import ArgumentParser
import BuildrHooksCore

struct UsageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage", abstract: "Collect account usage independently of repository hooks.",
        subcommands: [UsageRefreshCommand.self]
    )
}

struct UsageRefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh", abstract: "Collect and attempt publication of a fresh Codex usage observation."
    )
    @Option(name: .long, help: "Provider to collect (codex). May be repeated.")
    var provider: [String] = []
    @Option(name: .long, help: "Absolute path to an installed Codex executable.")
    var codexPath: String?
    @Flag(name: .long, help: "Emit the actual outcome as JSON.")
    var json = false
    func validate() throws {
        guard !provider.isEmpty, provider.allSatisfy({ $0 == "codex" }) else {
            throw ValidationError("Select --provider codex. Only Codex usage is supported.")
        }
    }

    func run() throws {
        let runtime = UsageRuntime(fetcher: CodexUsageFetcher(executablePath: codexPath))
        let result = runtime.refresh(json: json)
        if result.outcome.exitCode != 0 {
            throw ExitCode(result.outcome.exitCode)
        }
    }
}
