import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import Foundation
import Testing

struct ReportInjectedCommandTests {
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
