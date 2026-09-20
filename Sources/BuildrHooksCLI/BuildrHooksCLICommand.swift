import ArgumentParser
import BuildrHooksCore
import Foundation

@main
struct BuildrHooksCLICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "buildrhooks",
        abstract: "Relay hook events into BuildrAI's raw hook queue.",
        version: version,
        subcommands: [CodexCommand.self, ClaudeCommand.self, CapabilitiesCommand.self]
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

struct ClaudeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: HookAgentKind.claude.rawValue,
        abstract: "Ingest a Claude Code hook event.",
        subcommands: [
            ClaudeSessionStartCommand.self,
            ClaudePromptSubmitCommand.self,
            ClaudeStopCommand.self
        ]
    )
}

private protocol HookEventExecutable: ParsableCommand {
    static var hookAgentKind: HookAgentKind { get }
    static var hookEventKind: HookEventKind { get }
}

extension HookEventExecutable {
    func run() throws {
        do {
            try BuildrHooksCLIEntrypoint().run(
                arguments: [
                    CommandLine.arguments.first ?? "buildrhooks",
                    Self.hookAgentKind.rawValue,
                    Self.hookEventKind.rawValue
                ]
            )
        } catch let exit as PromptGateExit {
            throw ExitCode(exit.code.rawValue)
        }
    }
}

struct CodexSessionStartCommand: HookEventExecutable {
    static let hookAgentKind: HookAgentKind = .codex
    static let configuration = CommandConfiguration(
        commandName: HookEventKind.sessionStart.rawValue,
        abstract: "Relay a Codex session-start hook event."
    )

    static let hookEventKind: HookEventKind = .sessionStart
}

struct CodexPromptSubmitCommand: HookEventExecutable {
    static let hookAgentKind: HookAgentKind = .codex
    static let configuration = CommandConfiguration(
        commandName: HookEventKind.promptSubmit.rawValue,
        abstract: "Relay a Codex prompt-submit hook event."
    )

    static let hookEventKind: HookEventKind = .promptSubmit
}

struct CodexStopCommand: HookEventExecutable {
    static let hookAgentKind: HookAgentKind = .codex
    static let configuration = CommandConfiguration(
        commandName: HookEventKind.stop.rawValue,
        abstract: "Relay a Codex stop hook event."
    )

    static let hookEventKind: HookEventKind = .stop
}

struct ClaudeSessionStartCommand: HookEventExecutable {
    static let hookAgentKind: HookAgentKind = .claude
    static let hookEventKind: HookEventKind = .sessionStart
    static let configuration = CommandConfiguration(
        commandName: HookEventKind.sessionStart.rawValue,
        abstract: "Relay a Claude Code SessionStart hook event."
    )
}

struct ClaudePromptSubmitCommand: HookEventExecutable {
    static let hookAgentKind: HookAgentKind = .claude
    static let hookEventKind: HookEventKind = .promptSubmit
    static let configuration = CommandConfiguration(
        commandName: HookEventKind.promptSubmit.rawValue,
        abstract: "Relay a Claude Code UserPromptSubmit hook event."
    )
}

struct ClaudeStopCommand: HookEventExecutable {
    static let hookAgentKind: HookAgentKind = .claude
    static let hookEventKind: HookEventKind = .stop
    static let configuration = CommandConfiguration(
        commandName: HookEventKind.stop.rawValue,
        abstract: "Relay a Claude Code Stop hook event."
    )
}

struct CapabilitiesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "capabilities",
        abstract: "Report BuildrHooksCLI capabilities."
    )

    @Flag(name: .long, help: "Emit machine-readable JSON.")
    var json = false

    func run() throws {
        let capabilities = BuildrHooksCapabilities.current
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileHandle.standardOutput.write(encoder.encode(capabilities))
            print()
        } else {
            print(
                "BuildrHooksCLI \(capabilities.version): \(capabilities.agents.map(\.rawValue).joined(separator: ", "))"
            )
        }
    }
}
