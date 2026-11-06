import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import Foundation
import Testing

struct ReportCancellationCommandTests {
    @Test func cancellingAnIdlePreparationPreservesOtherRepositories() throws {
        let fixture = try ReportFixture()
        let other = try ReportFixture()
        defer { fixture.close(); other.close() }
        _ = try fixture.generatedInput()
        _ = try other.generatedInput()
        try fixture.runCancellation("request-1")
        #expect(try fixture.response().body == .cancelled(.init(targetRequestID: "request-1")))
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
        #expect(FileManager.default.fileExists(atPath: other.requestDirectory.appending(path: "packet.json").path))
        #expect(fixture.launches == 1)
    }

    @Test func cancellingPreparationDuringFinalizationRejectsLateMarkdown() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.generatedInput()
        fixture.respond = { _ in
            try fixture.runCancellation("request-1")
            return .finalized(.init(snapshot: input.packet.snapshot, markdown: "Late report must not escape"))
        }
        #expect(throws: ExitCode(32)) { try fixture.runFinalization(input.url) }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected cancellation"); return
        }
        #expect(failure.code == .cancelled)
        #expect(try !#require(fixture.output.last).contains("Late report"))
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }

    @Test func cancellationCannotCrossProjectIdentityAtTheSameRoot() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        _ = try fixture.generatedInput()
        let scope = BridgeScope(repository: fixture.scope.repository, projectID: "other-project",
                                rootPath: fixture.scope.rootPath)
        try JSONEncoder().encode(scope).write(to: fixture.scopeURL)
        #expect(throws: ExitCode(32)) { try fixture.runCancellation("request-1") }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected rejected scope"); return
        }
        #expect(failure.code == .invalidInput)
        #expect(FileManager.default.fileExists(atPath: fixture.requestDirectory.appending(path: "packet.json").path))
    }

    @Test func timedOutIdentityCannotBeReusedToAcceptLateData() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "private-query"])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(fixture.launches == 1)
        fixture.respond = { _ in .error(.init(code: .unresolved, action: "Late response")) }
        #expect(throws: ExitCode(32)) { try command.run() }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected fenced identity"); return
        }
        #expect(failure.code == .invalidInput)
        #expect(fixture.launches == 1)
        let receipt = fixture.requestDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ended/request-1.json")
        let text = try String(contentsOf: receipt, encoding: .utf8)
        #expect(!text.contains("private-query"))
        #expect(text.contains("timeout"))
    }

    @Test func stalledLaunchCannotExtendTheRequestDeadline() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "session"])
        command.makeExecution = {
            var execution = fixture.execution
            execution.launch = { fixture.instant = 200; return .launched }
            execution.wait = { _ in Issue.record("Expired launch must not start another wait") }
            return execution
        }
        #expect(throws: ExitCode(32)) { try command.run() }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected bounded launch timeout"); return
        }
        #expect(failure.code == .timeout)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }
}

extension ReportFixture {
    func runCancellation(_ identifier: String) throws {
        var command = try #require(try BuildrHooksCLICommand.parseAsRoot([
            "report", "cancel", "--scope", scopeURL.path, "--request", identifier
        ]) as? ReportCancelCommand)
        command.makeExecution = {
            var execution = self.execution
            execution.requestID = { "cancel-1" }
            return execution
        }
        try command.run()
    }
}
