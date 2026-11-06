import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import Foundation
import Testing

struct ReportFinalizeCommandTests {
    @Test func preparedWorkflowReturnsExactAppMarkdownAndCleansOnlyItsHandoffs() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let packet = try fixture.preparedPacket()
        let preparation = try fixture.writePreparation(packet)
        fixture.respond = { _ in .prepared(packet) }
        try fixture.runPreparation(preparation.url)
        let generated = try BridgeCompatibilityFixtures.finalizationExample()
        let content = BridgeGeneratedContent(snapshot: packet.snapshot, summaries: generated.summaries,
                                             groups: generated.groups)
        let url = fixture.root.appending(path: "generated.json")
        try JSONEncoder().encode(content).write(to: url)
        let markdown = "# App report\r\n\r\nRésumé 🛠  \n<!-- exact -->\n"
        fixture.respond = { request in
            #expect(request.body == .finalize(content))
            #expect(request.requestID != packet.snapshot.requestID)
            #expect(FileManager.default.fileExists(
                atPath: fixture.requestDirectory.appending(path: "packet.json").path
            ))
            return .finalized(.init(snapshot: packet.snapshot, markdown: markdown))
        }
        try fixture.runFinalization(url)
        guard case let .finalized(report) = try fixture.response().body else {
            Issue.record("Expected finalized report"); return
        }
        #expect(Array(report.markdown.utf8) == Array(markdown.utf8))
        #expect(report.snapshot == packet.snapshot)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
        #expect(!FileManager.default.fileExists(atPath:
            fixture.requestDirectory.deletingLastPathComponent().appending(path: "finalize-1").path))
        #expect(fixture.diagnostics.isEmpty)
    }

    @Test func replacementMetricsAreRejectedWithoutContactingTheApp() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.generatedInput()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: input.url)) as? [String: Any])
        json["rollupMetrics"] = ["inputTokens": ["available": ["_0": 999_999]]]
        try JSONSerialization.data(withJSONObject: json).write(to: input.url)
        fixture.respond = { _ in .finalized(.init(snapshot: input.packet.snapshot, markdown: "must not render")) }
        #expect(throws: ExitCode(32)) { try fixture.runFinalization(input.url) }
        #expect(fixture.launches == 1)
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected structured invalid input"); return
        }
        #expect(failure.code == .invalidInput)
        #expect(FileManager.default.fileExists(atPath: fixture.requestDirectory.appending(path: "packet.json").path))
    }

    @Test(arguments: ["reference", "outcome", "disclosure", "selection", "head", "scope", "workflow"])
    func changedEvidenceOrContextCannotFinalize(kind: String) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.generatedInput()
        let retained = try Data(contentsOf: fixture.requestDirectory.appending(path: "packet.json"))
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: input.url)) as? [String: Any])
        if kind == "reference" || kind == "outcome" {
            var groups = try #require(json["groups"] as? [[String: Any]])
            groups[0][kind == "reference" ? "evidenceIDs" : "outcome"] =
                kind == "reference" ? ["invented-evidence"] : "failure"
            json["groups"] = groups
        } else {
            var snapshot = try #require(json["snapshot"] as? [String: Any])
            switch kind {
            case "disclosure": snapshot["disclosure"] = ["policyRevision": "changed", "includeOriginalPrompts": true]
            case "selection": snapshot["selection"] = [["source": "claude", "sessionID": "other"]]
            case "workflow": snapshot["requestID"] = "other-workflow"
            case "head":
                var target = try #require(snapshot["target"] as? [String: Any])
                target["head"] = String(repeating: "f", count: 40)
                snapshot["target"] = target
            default:
                var scope = try #require(snapshot["scope"] as? [String: Any])
                scope["projectID"] = "other-project"
                snapshot["scope"] = scope
            }
            json["snapshot"] = snapshot
        }
        try JSONSerialization.data(withJSONObject: json).write(to: input.url)
        #expect(throws: ExitCode(32)) { try fixture.runFinalization(input.url) }
        #expect(fixture.launches == 1)
        #expect(try Data(contentsOf: fixture.requestDirectory.appending(path: "packet.json")) == retained)
    }

    @Test(arguments: [BridgeFailure.Code.staleSnapshot, .invalidInput, .unusableEvidence, .busy])
    func appRejectionIsPreservedAndWorkflowCanBeRetried(code: BridgeFailure.Code) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.generatedInput()
        let failure = BridgeFailure(code: code, action: "Narrow selection below the app size budget, then retry.")
        fixture.respond = { _ in .error(failure) }
        #expect(throws: ExitCode(32)) { try fixture.runFinalization(input.url) }
        #expect(try fixture.response().body == .error(failure))
        #expect(FileManager.default.fileExists(atPath: fixture.requestDirectory.appending(path: "packet.json").path))
        fixture.respond = { _ in .finalized(.init(snapshot: input.packet.snapshot, markdown: "Retried exactly\n")) }
        try fixture.runFinalization(input.url)
        #expect(try fixture.response().body == .finalized(.init(snapshot: input.packet.snapshot,
                                                                markdown: "Retried exactly\n")))
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }

    @Test(arguments: ["silence", "timeout", "cancelled"])
    func terminalTimeoutOrCancellationCleansOnlyIdentifiedWorkflow(kind: String) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.generatedInput()
        let unrelated = fixture.requestDirectory.deletingLastPathComponent().appending(path: "unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: false)
        let sentinel = unrelated.appending(path: "packet.json")
        try Data("other workflow".utf8).write(to: sentinel)
        if kind == "silence" {
            fixture.respond = nil
        } else {
            fixture.respond = { _ in .error(.init(code: kind == "timeout" ? .timeout : .cancelled,
                                                  action: "Workflow ended.")) }
        }
        #expect(throws: ExitCode(32)) { try fixture.runFinalization(input.url) }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected terminal workflow failure"); return
        }
        #expect(failure.code == (kind == "cancelled" ? .cancelled : .timeout))
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "other workflow")
    }

    @Test(arguments: ["prepared", "snapshot", "oversized"])
    func latePreparationAndInvalidFinalArtifactsDoNotCompleteTheWorkflow(kind: String) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.generatedInput()
        fixture.respond = { _ in
            if kind == "prepared" {
                return .prepared(input.packet)
            }
            let snapshot = kind == "snapshot"
                ? try BridgeCompatibilityFixtures.finalizationExample().snapshot : input.packet.snapshot
            return .finalized(.init(snapshot: snapshot,
                                    markdown: kind == "oversized" ? String(repeating: "x", count: 65537) : "wrong"))
        }
        #expect(throws: ExitCode(32)) { try fixture.runFinalization(input.url) }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected rejected final artifact"); return
        }
        #expect(failure.code == .invalidInput)
        #expect(FileManager.default.fileExists(atPath: fixture.requestDirectory.appending(path: "packet.json").path))
        #expect(fixture.diagnostics.isEmpty)
    }

    @Test(arguments: [ReportAppState.unavailable, .failed])
    func failedFinalizationLaunchKeepsPreparedWorkflow(state: ReportAppState) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let input = try fixture.generatedInput()
        fixture.launchState = state
        #expect(throws: ExitCode(32)) { try fixture.runFinalization(input.url) }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected launch failure"); return
        }
        #expect(failure.code == (state == .unavailable ? .appUnavailable : .launchFailed))
        #expect(FileManager.default.fileExists(atPath: fixture.requestDirectory.appending(path: "packet.json").path))
    }

    @Test(arguments: ["packet", "directory", "request"])
    func substitutedPreparedStateIsRejectedWithoutDeletingItsOwner(kind: String) throws {
        let fixture = try ReportFixture()
        let other = try ReportFixture()
        defer { fixture.close(); other.close() }
        let input = try fixture.generatedInput()
        let otherInput = try other.generatedInput()
        let name = kind == "request" ? "request.json" : "packet.json"
        let destination = fixture.requestDirectory.appending(path: name)
        if kind == "directory" {
            try FileManager.default.removeItem(at: fixture.requestDirectory)
            try FileManager.default.createSymbolicLink(at: fixture.requestDirectory,
                                                       withDestinationURL: other.requestDirectory)
        } else {
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.createSymbolicLink(at: destination,
                                                       withDestinationURL: other.requestDirectory.appending(path: name))
        }
        #expect(throws: ExitCode(32)) { try fixture.runFinalization(input.url) }
        #expect(fixture.launches == 1)
        #expect(FileManager.default.fileExists(
            atPath: other.requestDirectory.appending(path: "packet.json").path
        ))
        #expect(otherInput.packet.snapshot.scope == other.scope)
    }
}

extension ReportFixture {
    func generatedInput() throws -> (packet: BridgeEvidencePacket, url: URL) {
        let packet = try preparedPacket()
        let preparation = try writePreparation(packet)
        respond = { _ in .prepared(packet) }
        try runPreparation(preparation.url)
        let generated = try BridgeCompatibilityFixtures.finalizationExample()
        let content = BridgeGeneratedContent(snapshot: packet.snapshot, summaries: generated.summaries,
                                             groups: generated.groups)
        let url = root.appending(path: "generated.json")
        try JSONEncoder().encode(content).write(to: url)
        return (packet, url)
    }

    func runFinalization(_ url: URL) throws {
        let command = try BuildrHooksCLICommand.parseAsRoot([
            "report", "finalize", "--scope", scopeURL.path, "--generated", url.path, "--timeout", "1"
        ])
        var finalize = try #require(command as? ReportFinalizeCommand)
        finalize.makeExecution = {
            var execution = self.execution
            execution.requestID = { "finalize-1" }
            execution.wait = { duration in
                self.instant += duration
                let directory = self.requestDirectory.deletingLastPathComponent().appending(path: "finalize-1")
                let data = try Data(contentsOf: directory.appending(path: "request.json"))
                let request = try JSONDecoder().decode(BridgeRequest.self, from: data)
                if let respond = self.respond {
                    let body = try respond(request)
                    let response = BridgeResponse(version: 1, requestID: request.requestID,
                                                  scope: request.scope, body: body)
                    try JSONEncoder().encode(self.transform?(response) ?? response)
                        .write(to: directory.appending(path: "response.json"))
                }
            }
            return execution
        }
        try finalize.run()
    }
}
