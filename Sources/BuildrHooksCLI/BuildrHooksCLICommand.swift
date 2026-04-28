import ArgumentParser
import BuildrHooksCore
import Foundation

@main
struct BuildrHooksCLICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "buildrhooks",
        abstract: "Relay hook events into BuildrAI's raw hook queue.",
        version: version,
        subcommands: [CodexCommand.self]
    )
}

struct CodexCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: HookAgentKind.codex.rawValue,
        abstract: "Ingest a Codex hook event.",
        subcommands: [
            CodexSessionStartCommand.self,
            CodexPromptSubmitCommand.self,
            CodexStopCommand.self
        ]
    )
}

private protocol HookEventExecutable: ParsableCommand {
    static var hookEventKind: HookEventKind { get }
}

extension HookEventExecutable {
    func run() throws {
        try BuildrHooksCLIEntrypoint().run(
            arguments: [
                CommandLine.arguments.first ?? "buildrhooks",
                HookAgentKind.codex.rawValue,
                Self.hookEventKind.rawValue
            ]
        )
    }
}

struct CodexSessionStartCommand: HookEventExecutable {
    static let configuration = CommandConfiguration(
        commandName: HookEventKind.sessionStart.rawValue,
        abstract: "Relay a Codex session-start hook event."
    )

    static let hookEventKind: HookEventKind = .sessionStart
}

struct CodexPromptSubmitCommand: HookEventExecutable {
    static let configuration = CommandConfiguration(
        commandName: HookEventKind.promptSubmit.rawValue,
        abstract: "Relay a Codex prompt-submit hook event."
    )

    static let hookEventKind: HookEventKind = .promptSubmit
}

struct CodexStopCommand: HookEventExecutable {
    static let configuration = CommandConfiguration(
        commandName: HookEventKind.stop.rawValue,
        abstract: "Relay a Codex stop hook event."
    )

    static let hookEventKind: HookEventKind = .stop
}
