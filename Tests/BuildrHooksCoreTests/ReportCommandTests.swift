import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import BuildrHooksCore
import Foundation
import Testing

struct ReportCommandTests {
    @Test func preparationIsRegisteredInNormalExecutable() throws {
        let command = try BuildrHooksCLICommand.parseAsRoot([
            "report", "prepare", "--scope", "/scope.json", "--preparation", "/selection.json"
        ])
        #expect(type(of: command).configuration.commandName == "prepare")
    }

    @Test func reportingCommandsAreRegisteredInNormalExecutable() throws {
        let command = try BuildrHooksCLICommand.parseAsRoot([
            "report", "discover", "--scope", "/scope.json", "--target", "/pr.json"
        ])
        #expect(type(of: command).configuration.commandName == "discover")
    }

    @Test func executableCapabilitiesAdvertisePreparation() {
        #expect(BuildrHooksCapabilities.current.reportingTracking.implementedOperations == [
            .discover, .resolve, .prepare
        ])
    }

    @Test(arguments: [ReportAppState.running, .launched])
    func resolutionReturnsAmbiguousSourceChoicesUnchanged(state: ReportAppState) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        fixture.launchState = state
        let choices = [BridgeSource.codex, .claude].map {
            BridgeCandidate(session: .init(source: $0, sessionID: "same-id"), header: "App header",
                            parent: nil, children: [], provenance: [.init(kind: .manual, commit: nil)],
                            coverage: .init(state: .complete, notes: []))
        }
        fixture.respond = { request in
            #expect(request.body == .resolve(.init(query: "same-id", source: nil)))
            return .resolved(.init(query: "same-id", choices: choices))
        }
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "same-id"])
        command.makeExecution = { fixture.execution }
        try command.run()
        #expect(try fixture.response().body == .resolved(.init(query: "same-id", choices: choices)))
    }

    @Test(arguments: ["buildrai://session/codex/one", "raw-session-id", "older feature work"])
    func broaderResolutionForwardsAuthorizedQueryAndSource(query: String) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        fixture.respond = { request in
            #expect(request.body == .resolve(.init(query: query, source: .codex)))
            return .error(.init(code: .unresolved, action: "Search another authorized project or session."))
        }
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", query, "--source", "codex"])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected unresolved error"); return
        }
        #expect(failure.code == .unresolved)
    }

    @Test(arguments: [ReportAppState.unavailable, .failed])
    func missingAndFailedLaunchAreActionable(state: ReportAppState) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        fixture.launchState = state
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "session"])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected launch error"); return
        }
        #expect(failure.code == (state == .unavailable ? .appUnavailable : .launchFailed))
        #expect(!failure.action.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }

    @Test(arguments: [BridgeFailure.Code.missingSetup, .missingAccess, .busy, .ambiguous])
    func appFailuresRemainStructuredAndActionable(code: BridgeFailure.Code) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let failure = BridgeFailure(code: code, action: "Open BuildrAI and review authorized project setup.")
        fixture.respond = { _ in .error(failure) }
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "session"])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(try fixture.response().body == .error(failure))
    }

    @Test func silenceAndProgressNeverBecomeEmptyCandidates() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        fixture.respond = { _ in .progress(.init(stage: .loading, message: "Private content is not logged")) }
        var command = try ReportDiscoverCommand.parse(fixture.arguments + ["--target", fixture.targetURL.path])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected timeout"); return
        }
        #expect(failure.code == .timeout)
        #expect(fixture.instant <= 101.01)
        #expect(fixture.diagnostics == ["BuildrAI: loading"])
        #expect(!fixture.output.joined().contains("Private content"))
    }

    @Test(arguments: ["identity", "scope", "operation", "version"])
    func mismatchedResponseIsRejected(kind: String) throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        fixture.transform = { response in
            let scope = BridgeScope(repository: fixture.scope.repository, projectID: "other-project",
                                    rootPath: fixture.scope.rootPath)
            let wrongBody = BridgeResponseBody.discovered(
                .init(candidates: [], coverage: .init(state: .complete, notes: []))
            )
            return BridgeResponse(version: kind == "version" ? 2 : 1,
                                  requestID: kind == "identity" ? "other-request" : response.requestID,
                                  scope: kind == "scope" ? scope : response.scope,
                                  body: kind == "operation" ? wrongBody : response.body)
        }
        fixture.respond = { _ in .error(.init(code: .unresolved, action: "No authorized match.")) }
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "session"])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        guard case let .error(failure) = try fixture.response().body else {
            Issue.record("Expected rejected response"); return
        }
        #expect(failure.code == .invalidInput)
    }

    @Test func invalidForkScopeNeverLaunchesOrPublishes() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let other = BridgeRepository(host: "github.com", owner: "fork", name: "repo")
        try JSONEncoder().encode(BridgePullRequest(
            baseRepository: fixture.scope.repository, sourceRepository: other, number: 48,
            head: String(repeating: "a", count: 40), commits: [String(repeating: "a", count: 40)]
        )).write(to: fixture.targetURL)
        var command = try ReportDiscoverCommand.parse(fixture.arguments + ["--target", fixture.targetURL.path])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(fixture.launches == 0)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }

    @Test func existingRequestArtifactsAreNeverDeletedByACompetingCaller() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        try FileManager.default.createDirectory(at: fixture.requestDirectory, withIntermediateDirectories: true)
        let sentinel = fixture.requestDirectory.appending(path: "owned-by-other")
        try Data("retained".utf8).write(to: sentinel)
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "session"])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(try String(contentsOf: sentinel, encoding: .utf8) == "retained")
        #expect(fixture.launches == 0)
    }

    @Test func sameRepositoryIsBusyWhileOtherRepositoriesProceed() throws {
        let fixture = try ReportFixture()
        let other = try ReportFixture()
        defer { fixture.close(); other.close() }
        other.respond = { _ in .error(.init(code: .unresolved, action: "No matching session.")) }
        var competitorOutput: [String] = []
        fixture.respond = { _ in
            var competitor = try ReportResolveCommand.parse(fixture.arguments + ["--query", "another"])
            competitor.makeExecution = {
                var execution = fixture.execution
                execution.requestID = { "request-2" }
                execution.output = { competitorOutput.append($0) }
                return execution
            }
            #expect(throws: ExitCode(32)) { try competitor.run() }
            var independent = try ReportResolveCommand.parse(other.arguments + ["--query", "other"])
            independent.makeExecution = { other.execution }
            #expect(throws: ExitCode(32)) { try independent.run() }
            return .discovered(.init(candidates: [], coverage: .init(state: .complete, notes: [])))
        }
        var command = try ReportDiscoverCommand.parse(fixture.arguments + ["--target", fixture.targetURL.path])
        command.makeExecution = { fixture.execution }
        try command.run()
        let busyData = try Data(#require(competitorOutput.first).utf8)
        let busy = try JSONDecoder().decode(BridgeResponse.self, from: busyData)
        guard case let .error(failure) = busy.body else { Issue.record("Expected busy"); return }
        #expect(failure.code == .busy)
        #expect(fixture.launches == 1)
        #expect(other.launches == 1)
        let empty = BridgeDiscoveryResult(candidates: [], coverage: .init(state: .complete, notes: []))
        #expect(try fixture.response().body == .discovered(empty))
    }

    @Test func symlinkedHandoffCannotReachAnotherProject() throws {
        let fixture = try ReportFixture()
        let other = try ReportFixture()
        defer { fixture.close(); other.close() }
        try FileManager.default.createSymbolicLink(at: fixture.root.appending(path: ".buildrai"),
                                                   withDestinationURL: other.root)
        var command = try ReportResolveCommand.parse(fixture.arguments + ["--query", "session"])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        #expect(fixture.launches == 0)
        #expect(!FileManager.default.fileExists(atPath: other.root.appending(path: "reporting").path))
    }

    @Test func responseAtDeadlineIsFencedAndSilenceIsBounded() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        fixture.respond = { _ in
            fixture.instant = 101
            return .discovered(.init(candidates: [], coverage: .init(state: .complete, notes: [])))
        }
        var command = try ReportDiscoverCommand.parse(fixture.arguments + ["--target", fixture.targetURL.path])
        command.makeExecution = { fixture.execution }
        #expect(throws: ExitCode(32)) { try command.run() }
        guard case let .error(failure) = try fixture.response().body else { Issue.record("Expected timeout"); return }
        #expect(failure.code == .timeout)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }

    @Test func discoveryPreservesAppCandidatesAndSeparatesProgress() throws {
        let fixture = try ReportFixture()
        defer { fixture.close() }
        let candidate = BridgeCandidate(
            session: .init(source: .codex, sessionID: "session-1"), header: "Existing app header",
            parent: nil, children: [.init(source: .claude, sessionID: "child")],
            provenance: [.init(kind: .recordedCommit, commit: String(repeating: "a", count: 40))],
            coverage: .init(state: .partial, notes: ["Older activity unavailable"])
        )
        let result = BridgeDiscoveryResult(candidates: [candidate], coverage: candidate.coverage)
        var replies = 0
        fixture.respond = { request in
            replies += 1
            if replies == 1 {
                return .progress(.init(stage: .loading, message: "Loading authorized sources"))
            }
            #expect(request.target?.commits == [String(repeating: "a", count: 40)])
            return .discovered(result)
        }
        var command = try ReportDiscoverCommand.parse(fixture.arguments + ["--target", fixture.targetURL.path])
        command.makeExecution = { fixture.execution }
        try command.run()
        let response = try fixture.response()
        #expect(response.body == .discovered(result))
        #expect(fixture.output.count == 1)
        #expect(fixture.diagnostics == ["BuildrAI: loading"])
        #expect(fixture.launches == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.requestDirectory.path))
    }
}

final class ReportFixture {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "report-\(UUID().uuidString)").resolvingSymlinksInPath()
    let scope: BridgeScope
    let scopeURL: URL
    let targetURL: URL
    var instant = 100.0
    var output: [String] = []
    var diagnostics: [String] = []
    var launches = 0
    var respond: ((BridgeRequest) throws -> BridgeResponseBody)?
    var transform: ((BridgeResponse) throws -> BridgeResponse)?
    var launchState = ReportAppState.launched
    var requestDirectory: URL {
        root.appending(path: ".buildrai/reporting/v1/requests/request-1")
    }

    var arguments: [String] {
        ["--scope", scopeURL.path, "--timeout", "1"]
    }

    init() throws {
        let repository = BridgeRepository(host: "github.com", owner: "owner", name: "repo")
        scope = .init(repository: repository, projectID: "authorized-project", rootPath: root.path)
        scopeURL = root.appending(path: "scope.json")
        targetURL = root.appending(path: "target.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try JSONEncoder().encode(scope).write(to: scopeURL)
        try JSONEncoder().encode(BridgePullRequest(
            baseRepository: repository, sourceRepository: repository, number: 48,
            head: String(repeating: "a", count: 40), commits: [String(repeating: "a", count: 40)]
        )).write(to: targetURL)
    }

    var execution: ReportCommandExecution {
        var execution = ReportCommandExecution()
        execution.now = { self.instant }
        execution.requestID = { "request-1" }
        execution.launch = { self.launches += 1; return self.launchState }
        execution.output = { self.output.append($0) }
        execution.diagnostic = { self.diagnostics.append($0) }
        execution.wait = { duration in
            self.instant += duration
            let url = self.requestDirectory.appending(path: "request.json")
            if let respond = self.respond, FileManager.default.fileExists(atPath: url.path) {
                let request = try JSONDecoder().decode(BridgeRequest.self, from: Data(contentsOf: url))
                let response = try BridgeResponse(version: 1, requestID: request.requestID,
                                                  scope: request.scope, body: respond(request))
                try JSONEncoder().encode(self.transform?(response) ?? response).write(
                    to: self.requestDirectory.appending(path: "response.json"), options: .atomic
                )
            }
        }
        return execution
    }

    func response() throws -> BridgeResponse {
        try JSONDecoder().decode(BridgeResponse.self, from: Data(#require(output.last).utf8))
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}
