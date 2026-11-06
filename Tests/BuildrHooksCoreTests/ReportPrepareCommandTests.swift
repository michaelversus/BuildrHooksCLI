import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import Foundation
import Testing

struct ReportPrepareCommandTests {
    @Test func confirmedSourcesAndAuthoritativeMultiSessionEvidenceSurvivePreparation() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let packet = try fixture.preparedPacket("prepare-multi-session")
        let input = try fixture.writePreparation(packet)
        var replies = 0
        fixture.respond = { request in
            #expect(request.body == .prepare(input.preparation))
            replies += 1
            if replies == 1 {
                return .progress(.init(stage: .preparing, message: "Sensitive app progress body"))
            }
            return .prepared(packet)
        }
        try fixture.runPreparation(input.url)
        #expect(try fixture.response().body == .prepared(packet))
        #expect(packet.snapshot.selection == [
            .init(source: .codex, sessionID: "session-1"), .init(source: .claude, sessionID: "session-1")
        ])
        #expect(packet.snapshot.target.commits == [String(repeating: "a", count: 40),
                                                   String(repeating: "b", count: 40)])
        #expect(packet.rollupMetrics.workingSeconds == .available(99))
        #expect(packet.sessions[0].records.map(\.evidenceID) == ["request-1", "evidence-1"])
        #expect(packet.sessions[0].modelSettings.map(\.model) == ["model-a", "model-b"])
        #expect(packet.sessions[0].modelSettings.map(\.reasoningEffort) == [nil, "high"])
        #expect(packet.sessions[0].skills.map(\.provenance) == [.explicit, .inferred, .pending])
        #expect(packet.sessions[1].coverage.state == .unavailable)
        #expect(packet.sessions[1].records.isEmpty)
        #expect(packet.coverage.notes == ["Running session; omitted/truncated records; one unavailable session."])
        #expect(fixture.diagnostics == ["BuildrAI: preparing"])
        #expect(!fixture.output.joined().contains("Sensitive app progress body"))
    }

    @Test func workflowPacketSurvivesLateResponsesAndCompetingRequestsAfterCollection() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let packet = try fixture.preparedPacket("prepare-multi-session")
        let input = try fixture.writePreparation(packet)
        fixture.respond = { _ in .prepared(packet) }
        try fixture.runPreparation(input.url)
        // A replaceable app slot cannot change the captured packet.
        try Data("late response".utf8).write(to: fixture.requestDirectory.appending(path: "response.json"))
        let retained = try Data(contentsOf: fixture.requestDirectory.appending(path: "packet.json"))
        #expect(try JSONDecoder().decode(BridgeEvidencePacket.self, from: retained) == packet)
        #expect(throws: ExitCode(32)) { try fixture.runPreparation(input.url) }
        guard case let .error(error) = try fixture.response().body else {
            Issue.record("Expected existing workflow to be protected"); return
        }
        #expect(error.code == .busy)
        #expect(try Data(contentsOf: fixture.requestDirectory.appending(path: "packet.json")) == retained)

        var next = try ReportResolveCommand.parse(fixture.arguments + ["--query", "next"])
        next.makeExecution = {
            var execution = fixture.execution
            execution.requestID = { "request-2" }
            execution.launch = { .unavailable }
            return execution
        }
        #expect(throws: ExitCode(32)) { try next.run() }
        guard case let .error(nextError) = try fixture.response().body else {
            Issue.record("Expected missing app after lock release"); return
        }
        #expect(nextError.code == .appUnavailable)
        #expect(try Data(contentsOf: fixture.requestDirectory.appending(path: "packet.json")) == retained)
    }

    @Test(arguments: ["error-ambiguous", "error-missingAccess", "error-unusableEvidence", "error-invalidInput"])
    func appPreparationFailuresStayStructured(name: String) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let shared = try JSONDecoder().decode(BridgeFixture.self, from: Data(contentsOf:
            BridgeCompatibilityFixtures.directory.appending(path: name + ".json")))
        let failure = try #require(shared.response?.body)
        let input = try fixture.writePreparation(fixture.preparedPacket())
        fixture.respond = { _ in failure }
        #expect(throws: ExitCode(32)) { try fixture.runPreparation(input.url) }
        #expect(try fixture.response().body == failure)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
        #expect(fixture.diagnostics.isEmpty)
    }

    @Test(arguments: ["selection", "disclosure", "target", "scope", "order"])
    func staleOrInvalidEvidenceCannotBecomeARetainedPacket(kind: String) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let packet = try fixture.preparedPacket("prepare-multi-session")
        let input = try fixture.writePreparation(packet)
        fixture.respond = { _ in .prepared(packet) }
        fixture.transform = { response in
            let data = try JSONEncoder().encode(response)
            var json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            var body = try #require(json["body"] as? [String: Any])
            var prepared = try #require(body["prepared"] as? [String: Any])
            var evidence = try #require(prepared["_0"] as? [String: Any])
            var snapshot = try #require(evidence["snapshot"] as? [String: Any])
            switch kind {
            case "selection": snapshot["selection"] = Array(packet.snapshot.selection.reversed()).map {
                    ["source": $0.source.rawValue, "sessionID": $0.sessionID]
                }
            case "disclosure": snapshot["disclosure"] = ["policyRevision": "changed", "includeOriginalPrompts": true]
            case "target":
                var target = try #require(snapshot["target"] as? [String: Any])
                target["number"] = 999
                snapshot["target"] = target
            case "scope":
                var scope = try #require(snapshot["scope"] as? [String: Any])
                scope["projectID"] = "unauthorized"
                snapshot["scope"] = scope
            default:
                var sessions = try #require(evidence["sessions"] as? [[String: Any]])
                let records = try #require(sessions[0]["records"] as? [[String: Any]])
                sessions[0]["records"] = Array(records.reversed())
                evidence["sessions"] = sessions
            }
            evidence["snapshot"] = snapshot
            prepared["_0"] = evidence
            body["prepared"] = prepared
            json["body"] = body
            return try JSONDecoder().decode(BridgeResponse.self, from: JSONSerialization.data(withJSONObject: json))
        }
        #expect(throws: ExitCode(32)) { try fixture.runPreparation(input.url) }
        guard case let .error(error) = try fixture.response().body else {
            Issue.record("Expected invalid evidence"); return
        }
        #expect(error.code == .invalidInput)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
        #expect(fixture.diagnostics.isEmpty)
    }

    @Test(arguments: [false, true])
    func rawResponseFieldsAreExcludedAndTransportBudgetIsEnforced(oversized: Bool) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let packet = try fixture.preparedPacket()
        let input = try fixture.writePreparation(packet)
        fixture.respond = { _ in .prepared(packet) }
        var command = try ReportPrepareCommand.parse([
            "--scope", fixture.scopeURL.path, "--timeout", "100", "--preparation", input.url.path
        ])
        command.makeExecution = {
            var execution = fixture.execution
            let wait = execution.wait
            execution.wait = { duration in
                try wait(duration)
                let url = fixture.requestDirectory.appending(path: "response.json")
                var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                json["rawTranscript"] = oversized
                    ? String(repeating: "x", count: 4 * 1024 * 1024) : "private transcript"
                json["toolOutput"] = "private tool output"
                try JSONSerialization.data(withJSONObject: json).write(to: url, options: .atomic)
            }
            return execution
        }
        if oversized {
            #expect(throws: ExitCode(32)) { try command.run() }
            guard case let .error(error) = try fixture.response().body else {
                Issue.record("Expected transport budget failure"); return
            }
            #expect(error.code == .invalidInput)
            #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
        } else {
            try command.run()
            #expect(try fixture.response().body == .prepared(packet))
            let retained = try String(
                contentsOf: fixture.requestDirectory.appending(path: "packet.json"), encoding: .utf8
            )
            #expect(!retained.contains("private transcript"))
            #expect(!retained.contains("private tool output"))
        }
        #expect(!fixture.output.joined().contains("private"))
        #expect(fixture.diagnostics.isEmpty)
    }

    @Test(arguments: ["empty", "duplicate", "foreignRepository"])
    func invalidConfirmedSelectionNeverLaunches(kind: String) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let packet = try fixture.preparedPacket()
        var target = packet.snapshot.target
        let selection: [BridgeSession]
        if kind == "empty" {
            selection = []
        } else if kind == "duplicate" {
            selection = [packet.snapshot.selection[0], packet.snapshot.selection[0]]
        } else {
            selection = packet.snapshot.selection
            target = .init(baseRepository: target.baseRepository,
                           sourceRepository: .init(host: "github.com", owner: "other", name: "repo"),
                           number: target.number, head: target.head, commits: target.commits)
        }
        let url = fixture.root.appending(path: "invalid.json")
        try JSONEncoder().encode(BridgePreparation(target: target, selection: selection,
                                                   disclosure: packet.snapshot.disclosure)).write(to: url)
        #expect(throws: ExitCode(32)) { try fixture.runPreparation(url) }
        #expect(fixture.launches == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }

    @Test func allUnavailableEvidenceIsAnActionableFailureAndIsNotRetained() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let packet = try fixture.preparedPacket("prepare-all-unavailable")
        let input = try fixture.writePreparation(packet)
        fixture.respond = { _ in .prepared(packet) }
        var command = try ReportPrepareCommand.parse([
            "--scope", fixture.scopeURL.path, "--timeout", "100", "--preparation", input.url.path
        ])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        guard case let .error(error) = try fixture.response().body else {
            Issue.record("Expected unusable evidence"); return
        }
        #expect(error.code == .unusableEvidence)
        #expect(!error.action.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }

    @Test func partialSnapshotIsReturnedUnchangedAndRetainedForGeneratedContent() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let packet = try fixture.preparedPacket()
        let input = try fixture.writePreparation(packet)
        fixture.respond = { request in
            #expect(request.body == .prepare(input.preparation))
            return .prepared(packet)
        }
        var command = try ReportPrepareCommand.parse([
            "--scope", fixture.scopeURL.path, "--timeout", "100", "--preparation", input.url.path
        ])
        command.makeExecution = { fixture.execution }
        try command.run()
        #expect(try fixture.response().body == .prepared(packet))
        #expect(packet.rollupMetrics.inputTokens == .unavailable("not reported"))
        #expect(packet.rollupMetrics.outputTokens == .available(0))
        #expect(packet.sessions[0].records.map(\.evidenceID) == ["evidence-1"])
        #expect(fixture.diagnostics.isEmpty)
        let retained = try JSONDecoder().decode(
            BridgeEvidencePacket.self,
            from: Data(contentsOf: fixture.requestDirectory.appending(path: "packet.json"))
        )
        #expect(retained == packet)
        let request = try JSONDecoder().decode(
            BridgeRequest.self, from: Data(contentsOf: fixture.requestDirectory.appending(path: "request.json"))
        )
        #expect(retained.snapshot.requestID == request.requestID)
        let generated = try BridgeCompatibilityFixtures.finalizationExample()
        let submission = BridgeGeneratedContent(snapshot: retained.snapshot, summaries: generated.summaries,
                                                groups: generated.groups)
        try BridgeValidator.validate(submission, against: retained)
    }
}

extension ReportFixture {
    func runPreparation(_ url: URL) throws {
        var command = try ReportPrepareCommand.parse([
            "--scope", scopeURL.path, "--timeout", "100", "--preparation", url.path
        ])
        command.makeExecution = { self.execution }
        try command.run()
    }

    func preparedPacket(_ name: String = "prepare-partial") throws -> BridgeEvidencePacket {
        let data = try Data(contentsOf: BridgeCompatibilityFixtures.directory.appending(path: name + ".json"))
        let shared = try JSONDecoder().decode(BridgeFixture.self, from: data)
        guard case let .prepared(original) = shared.response?.body else {
            throw BridgeValidationError.invalidPayload
        }
        let snapshot = original.snapshot
        let target = BridgePullRequest(
            baseRepository: snapshot.target.baseRepository, sourceRepository: scope.repository,
            number: snapshot.target.number, head: snapshot.target.head, commits: snapshot.target.commits
        )
        return BridgeEvidencePacket(
            snapshot: .init(snapshotID: snapshot.snapshotID, requestID: "request-1", scope: scope,
                            target: target, selection: snapshot.selection,
                            evidenceRevision: snapshot.evidenceRevision, disclosure: snapshot.disclosure,
                            capturedAt: snapshot.capturedAt),
            sessions: original.sessions, rollupMetrics: original.rollupMetrics, coverage: original.coverage
        )
    }

    func writePreparation(_ packet: BridgeEvidencePacket) throws -> (url: URL, preparation: BridgePreparation) {
        let preparation = BridgePreparation(target: packet.snapshot.target, selection: packet.snapshot.selection,
                                            disclosure: packet.snapshot.disclosure)
        let url = root.appending(path: "preparation.json")
        try JSONEncoder().encode(preparation).write(to: url)
        return (url, preparation)
    }
}
