import ArgumentParser
import BuildrHooksCore
import Foundation

struct UsageServiceCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "service", abstract: "Explicitly manage the independent account usage login service.",
        subcommands: [UsageServiceEnableCommand.self, UsageServiceDisableCommand.self, UsageServiceStatusCommand.self]
    )
}

struct UsageServiceEnableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Opt in to collection now and at login, independently of BuildrAI."
    )
    @Option(name: .long, help: "Explicit provider selection (codex); may be repeated.")
    var provider: [String] = []
    @Option(name: .long, help: "Override the stable, absolute CLI executable path.")
    var cliPath: String?
    @Option(
        name: .long,
        help: "Override the stable, absolute Codex executable path; Codex is never installed automatically."
    )
    var codexPath: String?
    @Flag(name: .long, help: "Emit service state as JSON; diagnostics go to stderr.")
    var json = false

    func run() throws {
        try reportService(json: json) {
            try UsageService().enable(providers: provider, cliPath: cliPath, codexPath: codexPath,
                                      currentExecutable: serviceExecutable())
        }
    }
}

struct UsageServiceDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Stop the login collector and remove automatic startup, retaining usage cache."
    )
    @Flag(name: .long, help: "Emit service state as JSON.")
    var json = false
    func run() throws {
        try reportService(json: json) { try UsageService().disable() }
    }
}

struct UsageServiceStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Inspect configured providers, process availability, and retained collection status."
    )
    @Flag(name: .long, help: "Emit service state as JSON without account-identifying details.")
    var json = false
    func run() throws {
        try reportService(json: json) { try UsageService().status() }
    }
}

private func serviceExecutable() -> String {
    let argument = CommandLine.arguments[0]
    if argument.hasPrefix("/") {
        return argument
    }
    if argument.contains("/") {
        return URL(fileURLWithPath: argument).standardizedFileURL.path
    }
    return (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
        .filter { $0.hasPrefix("/") }.map { "\($0)/\(argument)" }
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? argument
}

private func reportService(json: Bool, action: () throws -> UsageServiceStatus) throws {
    do {
        let status = try action()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try FileHandle.standardOutput.write(encoder.encode(status) + Data([10]))
        } else {
            print("Configured: \(status.configured); installed: \(status.installed)")
            print("Providers: \(status.enabledProviders.map(\.rawValue).joined(separator: ", "))")
            print(
                "Service process running: \(status.processRunning); collector available: \(status.collectorAvailable)"
            )
            print("Executable paths valid: \(status.executablesValid)")
            for collection in status.retainedCollectionStatus {
                print("Retained \(collection.provider.rawValue) collection status: \(collection.status.rawValue)")
            }
        }
    } catch {
        let failure = error as? UsageServiceError ?? .invalidConfiguration
        if json {
            let data = try JSONEncoder().encode(["error": failure.rawValue])
            FileHandle.standardOutput.write(data + Data([10]))
        }
        FileHandle.standardError.write(Data((failure.guidance + "\n").utf8))
        throw ExitCode(1)
    }
}
