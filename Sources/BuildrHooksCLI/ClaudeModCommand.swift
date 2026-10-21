import ArgumentParser
import Foundation

struct ClaudeModCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mod", abstract: "Prepare an opt-in Claude mod for Desktop reported quota.",
        subcommands: [ClaudeModSetupCommand.self, ClaudeModRemoveCommand.self, ClaudeStatusLineCaptureCommand.self]
    )

    static var assets: URL {
        Bundle.module.url(forResource: "ClaudeUsageMod", withExtension: nil)!
    }
}

struct ClaudeModSetupCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup", abstract: "Preview/export a mod; enabling it in Claude is a separate operator step."
    )
    @Option(name: .long, help: "Dedicated output directory; parent must exist. Never a live Claude settings root.")
    var directory: String
    @Option(name: .long, help: "Absolute executable path to invoke; defaults to this installed bridge.")
    var executable: String?
    @Flag(name: .long, help: "Prepare or upgrade only unmodified bridge-owned files after preview.")
    var apply = false

    func run() throws {
        guard let path = executable ?? Bundle.main.executableURL?.resolvingSymlinksInPath().path,
              path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
            throw ValidationError("Choose an existing absolute BuildrHooksCLI executable path.")
        }
        try print(ClaudeModSetup(directory: URL(fileURLWithPath: directory), assets: ClaudeModCommand.assets,
                                 executable: URL(fileURLWithPath: path)).setup(apply: apply))
    }
}

struct ClaudeModRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove", abstract: "Preview/remove an unmodified prepared mod; uninstall in Claude first."
    )
    @Option(name: .long, help: "Previously prepared dedicated output directory.") var directory: String
    @Flag(name: .long, help: "Remove only still-owned files after preview.") var apply = false

    func run() throws {
        try print(ClaudeModSetup(directory: URL(fileURLWithPath: directory), assets: ClaudeModCommand.assets,
                                 executable: URL(fileURLWithPath: "/unused")).remove(apply: apply))
    }
}
