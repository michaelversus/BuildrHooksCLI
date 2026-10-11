import ArgumentParser
@testable import BuildrHooksCLI
@testable import BuildrHooksCore
import Foundation
import Testing

struct UsageServiceCommandTests {
    @Test func commandHandlersEnableInspectAndDisableOnlyTheirInjectedService() throws {
        let fixture = try UsageServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var enable = try UsageServiceEnableCommand.parse([
            "--provider", "codex", "--cli-path", fixture.cli, "--codex-path", fixture.codex, "--json"
        ])
        enable.makeService = { fixture.service }
        try enable.run()
        #expect(fixture.manager.starts == 1 && fixture.manager.loaded)
        var status = try UsageServiceStatusCommand.parse([])
        status.makeService = { fixture.service }
        try status.run()
        #expect(fixture.manager.starts == 1 && fixture.manager.stops == 0)
        var disable = try UsageServiceDisableCommand.parse(["--json"])
        disable.makeService = { fixture.service }
        try disable.run()
        #expect(fixture.manager.stops == 1 && !fixture.manager.loaded)
        #expect(!FileManager.default.fileExists(atPath: fixture.service.plistURL.path))
    }

    @Test func serviceReporterEmitsParseableStateAndSanitizedFailures() throws {
        let fixture = try UsageServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let status = try fixture.service.status()
        var output = Data()
        var diagnostic = Data()
        try reportService(
            json: true, output: { output.append($0) },
            errorOutput: { diagnostic.append($0) }, action: { status }
        )
        #expect(try JSONDecoder().decode(UsageServiceStatus.self, from: output).processHealth == .stopped)
        #expect(diagnostic.isEmpty && output.last == 10)
        output = Data()
        try reportService(json: false, output: { output.append($0) }, action: { status })
        #expect(String(bytes: output, encoding: .utf8)?.contains("Service process health: stopped") == true)
        for error in [UsageServiceError.invalidProvider, .launchctlUnavailable, .managementBusy] {
            output = Data(); diagnostic = Data()
            #expect(throws: ExitCode(1)) {
                try reportService(
                    json: true, output: { output.append($0) },
                    errorOutput: { diagnostic.append($0) }, action: { throw error }
                )
            }
            #expect(try JSONDecoder().decode([String: String].self, from: output) == ["error": error.rawValue])
            #expect(String(bytes: diagnostic, encoding: .utf8) == error.guidance + "\n")
        }
        output = Data(); diagnostic = Data()
        #expect(throws: ExitCode(1)) {
            try reportService(
                json: false, output: { output.append($0) },
                errorOutput: { diagnostic.append($0) }, action: { throw CocoaError(.fileReadNoPermission) }
            )
        }
        #expect(output.isEmpty)
        #expect(String(bytes: diagnostic, encoding: .utf8) == UsageServiceError.invalidConfiguration.guidance + "\n")
    }

    @Test func serviceExecutableResolvesAbsoluteRelativeAndPathInvocations() throws {
        let fixture = try UsageServiceTests().fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(serviceExecutable(argument: fixture.cli) == fixture.cli)
        let relative = URL(fileURLWithPath: "./buildrhooks").standardizedFileURL.path
        #expect(serviceExecutable(argument: "./buildrhooks") == relative)
        #expect(serviceExecutable(argument: "stable cli", searchPath: "relative:" + fixture.root.path) == fixture.cli)
        #expect(serviceExecutable(argument: "missing", searchPath: fixture.root.path) == "missing")
    }
}
