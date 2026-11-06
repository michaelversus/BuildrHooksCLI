import ArgumentParser
import Foundation

struct TrackingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "tracking",
        abstract: "Record and replay durable source-aware commit associations without opening BuildrAI.",
        subcommands: [TrackingRecordCommitCommand.self, TrackingReplayCommand.self, TrackingAcknowledgeCommand.self]
    )
}

struct TrackingRecordCommitCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "record-commit")
    @Option(name: .long) var scope: String
    @Option(name: .long, help: "JSON successful Git tool completion, including stable invocation identity.")
    var execution: String
    enum CodingKeys: String, CodingKey { case scope, execution }
    var makeExecution: () -> TrackingCommandExecution = { TrackingCommandExecution() }
    func run() throws {
        do {
            try makeExecution().run(scopePath: scope, executionPath: execution)
        } catch is TrackingCommandFailure { throw ExitCode(33) }
    }
}

struct TrackingReplayCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "replay")
    @Option(name: .long) var scope: String
    enum CodingKeys: String, CodingKey { case scope }
    var makeExecution: () -> TrackingCommandExecution = { TrackingCommandExecution() }
    func run() throws {
        do {
            try makeExecution().run(scopePath: scope, executionPath: nil)
        } catch is TrackingCommandFailure { throw ExitCode(33) }
    }
}

struct TrackingAcknowledgeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acknowledge", abstract: "Acknowledge records only after durable app ingestion."
    )
    @Option(name: .long) var scope: String
    @Option(name: .long) var acknowledgement: String
    enum CodingKeys: String, CodingKey { case scope, acknowledgement }
    var makeExecution: () -> TrackingCommandExecution = { TrackingCommandExecution() }
    func run() throws {
        do {
            try makeExecution().run(scopePath: scope, executionPath: nil, acknowledgementPath: acknowledgement)
        } catch is TrackingCommandFailure { throw ExitCode(33) }
    }
}
