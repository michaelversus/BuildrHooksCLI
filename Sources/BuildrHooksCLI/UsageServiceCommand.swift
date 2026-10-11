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
        commandName: "enable",
        abstract: "Opt in to collection now and at login with throttled crash restart, independently of BuildrAI."
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

    enum CodingKeys: String, CodingKey { case provider, cliPath, codexPath, json }

    var makeService: () -> UsageService = { UsageService() }

    func run() throws {
        try reportService(json: json) {
            try makeService().enable(providers: provider, cliPath: cliPath, codexPath: codexPath,
                                     currentExecutable: serviceExecutable())
        }
    }
}

struct UsageServiceDisableCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Cancel the login collector, remove restart/startup, and retain committed usage cache."
    )
    @Flag(name: .long, help: "Emit service state as JSON.")
    var json = false
    enum CodingKeys: String, CodingKey { case json }

    var makeService: () -> UsageService = { UsageService() }

    func run() throws {
        try reportService(json: json) { try makeService().disable() }
    }
}

struct UsageServiceStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Inspect configured providers, process availability, and retained collection status."
    )
    @Flag(name: .long, help: "Emit service state as JSON without account-identifying details.")
    var json = false
    enum CodingKeys: String, CodingKey { case json }

    var makeService: () -> UsageService = { UsageService() }

    func run() throws {
        try reportService(json: json) { try makeService().status() }
    }
}

func serviceExecutable(
    argument: String = CommandLine.arguments[0],
    searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
) -> String {
    if argument.hasPrefix("/") {
        return argument
    }
    if argument.contains("/") {
        return URL(fileURLWithPath: argument).standardizedFileURL.path
    }
    return searchPath.split(separator: ":")
        .filter { $0.hasPrefix("/") }.map { "\($0)/\(argument)" }
        .first { FileManager.default.isExecutableFile(atPath: $0) } ?? argument
}

func reportService(
    json: Bool,
    output: (Data) throws -> Void = { try FileHandle.standardOutput.write(contentsOf: $0) },
    errorOutput: (Data) -> Void = { FileHandle.standardError.write($0) },
    action: () throws -> UsageServiceStatus
) throws {
    do {
        let status = try action()
        if json {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try output(encoder.encode(status) + Data([10]))
        } else {
            var lines = [
                "Configured: \(status.configured); installed: \(status.installed)",
                "Service process health: \(status.processHealth.rawValue)",
                "Providers: \(status.enabledProviders.map(\.rawValue).joined(separator: ", "))",
                "Service process running: \(status.processRunning); collector available: \(status.collectorAvailable)",
                "Executable paths valid: \(status.executablesValid)"
            ]
            lines += status.retainedCollectionStatus.map {
                "Retained \($0.provider.rawValue) collection status: \($0.status.rawValue)"
            }
            try output(Data((lines.joined(separator: "\n") + "\n").utf8))
        }
    } catch {
        let failure = error as? UsageServiceError ?? .invalidConfiguration
        if json {
            let data = try JSONEncoder().encode(["error": failure.rawValue])
            try output(data + Data([10]))
        }
        errorOutput(Data((failure.guidance + "\n").utf8))
        throw ExitCode(1)
    }
}
