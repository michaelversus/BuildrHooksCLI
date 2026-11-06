import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import Foundation
import Testing

struct ReportInjectedCommandTests {
    @Test func malformedSelectionReturnsSanitizedInvalidInputWithoutLaunching() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.writePreparation(fixture.preparedPacket())
        let data = try String(contentsOf: input.url, encoding: .utf8)
            .replacingOccurrences(of: "codex", with: "SENSITIVE_SENTINEL")
        try Data(data.utf8).write(to: input.url)
        #expect(throws: ExitCode(32)) { try fixture.runPreparation(input.url) }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected structured invalid input"); return
        }
        #expect(failure.code == .invalidInput)
        #expect(fixture.launches == 0)
        #expect(!fixture.output.joined().contains("SENSITIVE_SENTINEL"))
        #expect(fixture.diagnostics.isEmpty)
    }

    @Test func externallyManagedResponderSkipsNativeLaunchAndReturnsItsResult() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let result = try BridgeResolutionResult(query: "known-session",
                                                choices: [fixture.preparedPacket().sessions[0].candidate])
        fixture.respond = { _ in .resolved(result) }
        var command = try ReportResolveCommand.parse(fixture.arguments + [
            "--query", "known-session", "--no-launch"
        ])
        command.makeExecution = {
            var execution = fixture.execution
            execution.launch = { Issue.record("Native launch must be skipped"); return .failed }
            return execution
        }
        try command.run()
        #expect(try fixture.response().body == .resolved(result))
    }

    @Test(arguments: ["malformed", "invalid", "missing"])
    func invalidScopeReturnsAnUnboundSanitizedInputError(kind: String) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        if kind == "missing" {
            try FileManager.default.removeItem(at: fixture.scopeURL)
        } else {
            let text = try kind == "malformed" ? "{SENSITIVE_SENTINEL"
                : String(contentsOf: fixture.scopeURL, encoding: .utf8)
                .replacingOccurrences(of: "github.com", with: "SENSITIVE_SENTINEL")
            try Data(text.utf8).write(to: fixture.scopeURL)
        }
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "private-query"])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        let output = try #require(fixture.output.last)
        let result = try #require(JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
        #expect(result["version"] as? Int == 1)
        #expect(result["requestID"] as? String == "request-1")
        #expect(result["scope"] == nil)
        let body = try #require(result["body"] as? [String: Any])
        let error = try #require(body["error"] as? [String: Any])
        let failure = try #require(error["_0"] as? [String: Any])
        #expect(failure["code"] as? String == "invalidInput")
        #expect(!output.contains("SENSITIVE_SENTINEL"))
        #expect(!output.contains("private-query"))
        #expect(fixture.diagnostics.isEmpty)
        #expect(fixture.launches == 0)
    }

    @Test func injectedFilesystemAndStalledResponderRemainBoundedEvenWithAStoppedClock() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        var waited = 0.0
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "private-query"])
        command.makeExecution = {
            var execution = fixture.execution
            execution.files.readInput = { _ in try JSONEncoder().encode(fixture.scope) }
            execution.files.begin = { ProgressOnlyReportHandoff(request: $0) }
            execution.now = { 100 }
            execution.wait = { waited += $0 }
            return execution
        }
        #expect(throws: ExitCode(32)) { try command.run() }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected timeout rather than empty evidence"); return
        }
        #expect(failure.code == .timeout)
        #expect(waited > 0 && waited <= 1.01)
        #expect(fixture.diagnostics == ["BuildrAI: loading"])
        #expect(!fixture.output.joined().contains("private"))
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }
}

/// Test adapter for the public filesystem/responder effect, with no native app or disk transport.
private struct ProgressOnlyReportHandoff: ReportHandoff {
    let request: BridgeRequest
    func readResponse() throws -> BridgeResponse? {
        BridgeResponse(version: 1, requestID: request.requestID, scope: request.scope,
                       body: .progress(.init(stage: .loading, message: "private responder body")))
    }

    func retain(_: BridgeEvidencePacket) throws {}
    func complete() throws {}
    func close() {}
    func checkCancellation() throws {}
    func terminate(_: BridgeFailure.Code) throws {}
}
