import ArgumentParser
import BuildrBridgeContracts
import Foundation

struct ReportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report", abstract: "Request session evidence and exact rendered reports from BuildrAI.",
        subcommands: [
            ReportDiscoverCommand.self, ReportResolveCommand.self, ReportPrepareCommand.self, ReportFinalizeCommand.self
        ]
    )
}

struct ReportOptions: ParsableArguments {
    @Option(name: .long, help: "JSON file containing the caller-authorized v1 BridgeScope.")
    var scope: String
    @Option(name: .long, help: "Bounded wait in seconds (0.1–300).")
    var timeout: Double = 30

    func validate() throws {
        guard timeout.isFinite, (0.1 ... 300).contains(timeout) else {
            throw ValidationError("Use --timeout between 0.1 and 300 seconds.")
        }
    }
}

struct ReportDiscoverCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "discover")
    @OptionGroup var options: ReportOptions
    @Option(name: .long, help: "JSON v1 BridgePullRequest with base/source repositories, head and full commit set.")
    var target: String
    enum CodingKeys: String, CodingKey { case options, target }
    var makeExecution: () -> ReportCommandExecution = { ReportCommandExecution() }
    func run() throws {
        let execution = makeExecution()
        do {
            try execution.run(scopePath: options.scope, timeout: options.timeout) {
                try .discover(JSONDecoder().decode(BridgePullRequest.self,
                                                   from: execution.files.readInput(URL(fileURLWithPath: target))))
            }
        } catch is ReportCommandFailure { throw ExitCode(32) }
    }
}

struct ReportResolveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "resolve", abstract: "Search authorized sessions by text, BuildrAI reference or raw source ID."
    )
    @OptionGroup var options: ReportOptions
    @Option(name: .long) var query: String
    @Option(name: .long, help: "Optional source: codex or claude. Omit to preserve ambiguity choices.")
    var source: String?

    enum CodingKeys: String, CodingKey { case options, query, source }
    var makeExecution: () -> ReportCommandExecution = { ReportCommandExecution() }
    func run() throws {
        do {
            try makeExecution().run(scopePath: options.scope, timeout: options.timeout) {
                .resolve(.init(query: query, source: source.flatMap(BridgeSource.init(rawValue:))))
            }
        } catch is ReportCommandFailure { throw ExitCode(32) }
    }

    func validate() throws {
        if let source, !["codex", "claude"].contains(source) {
            throw ValidationError("Use --source codex or claude.")
        }
    }
}

/// Confirmed selection and disclosure are caller input; BuildrAI owns evidence preparation.
struct ReportPrepareCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "prepare", abstract: "Prepare a fixed evidence snapshot for confirmed sessions."
    )
    @OptionGroup var options: ReportOptions
    @Option(name: .long, help: "JSON v1 BridgePreparation with confirmed source-aware selection and disclosure.")
    var preparation: String

    enum CodingKeys: String, CodingKey { case options, preparation }
    var makeExecution: () -> ReportCommandExecution = { ReportCommandExecution() }
    func run() throws {
        let execution = makeExecution()
        do {
            try execution.run(scopePath: options.scope, timeout: options.timeout) {
                try .prepare(JSONDecoder().decode(
                    BridgePreparation.self, from: execution.files.readInput(URL(fileURLWithPath: preparation))
                ))
            }
        } catch is ReportCommandFailure { throw ExitCode(32) }
    }
}

/// Generated prose is caller supplied; the app validates and renders the final artifact.
struct ReportFinalizeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "finalize", abstract: "Submit generated content for exact app-rendered Markdown."
    )
    @OptionGroup var options: ReportOptions
    @Option(name: .long, help: "JSON v1 BridgeGeneratedContent using the retained prepared snapshot and evidence IDs.")
    var generated: String

    enum CodingKeys: String, CodingKey { case options, generated }
    var makeExecution: () -> ReportCommandExecution = { ReportCommandExecution() }
    func run() throws {
        let execution = makeExecution()
        do {
            try execution.run(scopePath: options.scope, timeout: options.timeout) {
                let data = try execution.files.readInput(URL(fileURLWithPath: generated))
                let content = try JSONDecoder().decode(BridgeGeneratedContent.self, from: data)
                // Codable ignores unknown fields. Reject them here so replacement metrics
                // and other caller-invented authoritative fields cannot masquerade as accepted input.
                let supplied = try JSONSerialization.jsonObject(with: data) as? NSDictionary
                let encoded = try JSONEncoder().encode(content)
                let canonical = try JSONSerialization.jsonObject(with: encoded) as? NSDictionary
                guard let supplied, let canonical, supplied == canonical else {
                    execution.diagnostic("Use only v1 generated summaries/groups and snapshot fields; "
                        + "metrics remain app-owned.")
                    throw ReportCommandFailure()
                }
                return .finalize(content)
            }
        } catch is ReportCommandFailure { throw ExitCode(32) }
    }
}
