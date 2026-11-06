import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import BuildrHooksCore
import Foundation
import Testing

struct ReportRecoveryCommandTests {
    @Test(arguments: [201.0, 86500.0])
    func preparedLeaseIsIndependentOfCollectionDeadline(now: Double) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        _ = try fixture.generatedInput()
        fixture.instant = now
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "next"])
        command.makeExecution = {
            var execution = fixture.execution
            execution.requestID = { "next" }
            execution.launch = { .unavailable }
            return execution
        }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(FileManager.default.fileExists(atPath: fixture.requestDirectory.path) == (now == 201))
    }

    @Test func interruptedFinalizationCleansItsValidatedPreparation() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.generatedInput()
        let content = try JSONDecoder().decode(BridgeGeneratedContent.self, from: Data(contentsOf: input.url))
        let directory = fixture.requestDirectory.deletingLastPathComponent().appending(path: "abandoned-finalize")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        try JSONEncoder().encode(BridgeRequest(version: 1, requestID: "abandoned-finalize", scope: fixture.scope,
                                               createdAt: 100, deadline: 101, body: .finalize(content)))
            .write(to: directory.appending(path: "request.json"))
        fixture.instant = 102
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "next"])
        command.makeExecution = {
            var execution = fixture.execution
            execution.requestID = { "next" }
            execution.launch = { .unavailable }
            return execution
        }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }

    @Test func crashAfterCompletionReceiptDoesNotRetainThePreparedPacket() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.generatedInput()
        let ended = fixture.requestDirectory.deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "ended/request-1.json")
        let request = try JSONDecoder().decode(BridgeRequest.self, from:
            Data(contentsOf: fixture.requestDirectory.appending(path: "request.json")))
        let scope = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.scope))
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "requestID": request.requestID, "scope": scope,
            "createdAt": request.createdAt, "deadline": request.deadline, "code": "completed"
        ]).write(to: ended)
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "next"])
        command.makeExecution = {
            var execution = fixture.execution
            execution.requestID = { "next" }
            execution.launch = { .unavailable }
            return execution
        }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
        #expect(input.packet.snapshot.requestID == "request-1")
    }

    @Test func cancellationCapabilityIsReadyForTheCompleteReportingCommandSet() {
        let capabilities = BuildrHooksCapabilities.current.reportingTracking
        #expect(capabilities.implementedOperations == [
            .discover, .resolve, .prepare, .finalize, .cancel, .recordCommit, .recordRewrite, .acknowledge
        ])
        #expect(capabilities.negotiate(version: 1, operation: "cancel").status == .ready)
    }

    @Test func explicitCancellationWinsOverLateCompletionAndDoesNotLaunchAnotherApp() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        var cancellationOutput: [String] = []
        fixture.respond = { _ in
            var command = try #require(try BuildrHooksCLICommand.parseAsRoot([
                "report", "cancel", "--scope", fixture.scopeURL.path, "--request", "request-1"
            ]) as? ReportCancelCommand)
            command.makeExecution = {
                var execution = fixture.execution
                execution.requestID = { "cancel-1" }
                execution.output = { cancellationOutput.append($0) }
                return execution
            }
            try command.run()
            return .discovered(.init(candidates: [], coverage: .init(state: .complete, notes: [])))
        }
        var command = try ReportDiscoverCommand.parse(fixture.arguments + ["--target", fixture.targetURL.path])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(try fixture.response().body == .error(.init(code: .cancelled, action: "Reporting workflow cancelled.")))
        let cancellationData = try Data(#require(cancellationOutput.first).utf8)
        let response = try JSONDecoder().decode(BridgeResponse.self, from: cancellationData)
        #expect(response.body == .cancelled(.init(targetRequestID: "request-1")))
        #expect(fixture.launches == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }

    @Test func expiredAbandonedRequestsAreRecoveredWithoutTouchingUnknownOrTrackingData() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let parent = fixture.requestDirectory.deletingLastPathComponent()
        let abandoned = parent.appending(path: "abandoned")
        let unknown = parent.appending(path: "unknown")
        let pending = fixture.root.appending(path: ".buildrai/tracking/pending.json")
        try FileManager.default.createDirectory(at: abandoned, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true)
        let trackingDirectory = pending.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: trackingDirectory, withIntermediateDirectories: true)
        try Data("durable association".utf8).write(to: pending)
        let request = BridgeRequest(version: 1, requestID: "abandoned", scope: fixture.scope,
                                    createdAt: 1, deadline: 2, body: .resolve(.init(query: "private", source: nil)))
        try JSONEncoder().encode(request).write(to: abandoned.appending(path: "request.json"))
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "session"])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(!FileManager.default.fileExists(atPath: abandoned.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(try String(contentsOf: pending, encoding: .utf8) == "durable association")
    }
}
