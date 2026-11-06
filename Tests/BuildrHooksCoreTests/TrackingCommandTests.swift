import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import BuildrHooksCore
import Foundation
import Testing

struct TrackingCommandTests {
    @Test func successfulCommitEmitsReceiptAndSurvivesRestartWithoutAnApp() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let result = try fixture.result()
        #expect(result.status == .queued)
        let record = try #require(result.records.first)
        #expect(result.records.count == 1)
        #expect(record.receipt.recordID.hasPrefix("commit-"))
        #expect(record.execution.invocationID == "invocation-1")
        #expect(record.receipt.session == BridgeSession(source: .codex, sessionID: "session-1"))
        #expect(record.receipt.commit == String(repeating: "b", count: 40))
        #expect(record.receipt.repository == fixture.scope.repository)
        #expect(record.execution.exitCode == 0)
        try fixture.replay()
        #expect(try fixture.result().records == [record])
    }

    @Test(arguments: ["failed", "unchanged", "mentioned", "scope", "abbreviated", "empty-session"])
    func nonCreatingOrMismatchedEvidenceIsRejected(kind: String) throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        var proof = fixture.proof
        switch kind {
        case "failed": proof.exitCode = 1
        case "unchanged": proof.headBefore = proof.headAfter
        case "mentioned": proof.argv = ["echo", proof.headAfter]
        case "scope": proof.rootPath = "/another-project"
        case "abbreviated": proof.headAfter = "abcdef0"
        default: proof.session = .init(source: .codex, sessionID: "")
        }
        try fixture.write(proof, "execution.json")
        #expect(throws: ExitCode(33)) { try fixture.record() }
        #expect(try fixture.result().status == .invalidInput)
        try fixture.replay()
        #expect(try fixture.result().records.isEmpty)
    }

    @Test func replayAndAcknowledgementAreIdempotentAcrossInterruptedIngestion() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let record = try #require(fixture.result().records.first)
        try fixture.record()
        try fixture.replay()
        #expect(try fixture.result().records == [record])
        // Simulate durable app ingestion, then interruption before acknowledgement.
        var ingested: Set<String> = [record.receipt.recordID]
        try fixture.replay()
        for value in try fixture.result().records {
            ingested.insert(value.receipt.recordID)
        }
        #expect(ingested.count == 1)
        try fixture.acknowledge([record.receipt.recordID])
        try fixture.acknowledge([record.receipt.recordID])
        try fixture.record()
        #expect(try fixture.result().status == .acknowledged)
        try fixture.replay()
        #expect(try fixture.result().records.isEmpty)
    }

    @Test func eventIdentityIncludesSourceAndSessionRatherThanOnlyInvocationID() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let first = try #require(fixture.result().records.first)
        var proof = fixture.proof
        proof.session = .init(source: .claude, sessionID: "session-1")
        try fixture.write(proof, "execution.json")
        try fixture.record()
        let second = try #require(fixture.result().records.first)
        #expect(first.receipt.recordID != second.receipt.recordID)
        try fixture.replay()
        #expect(try fixture.result().records.count == 2)
    }

    @Test func failedWritesNeverClaimCaptureAndFailedAcknowledgementRetainsReplay() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        fixture.failWrites = true
        #expect(throws: ExitCode(33)) { try fixture.record() }
        #expect(try fixture.result().status == .failed)
        #expect(try fixture.result().records.isEmpty)
        fixture.failWrites = false
        try fixture.record()
        let record = try #require(fixture.result().records.first)
        fixture.failWrites = true
        #expect(throws: ExitCode(33)) { try fixture.acknowledge([record.receipt.recordID]) }
        fixture.failWrites = false
        try fixture.replay()
        #expect(try fixture.result().records == [record])
        try fixture.acknowledge([record.receipt.recordID])
        try fixture.replay()
        #expect(try fixture.result().records.isEmpty)
    }

    @Test(arguments: ["disabled", "missing", "incompatible", "wrong-scope", "malformed"])
    func appOwnedConfigurationProducesActionableStatusWithoutBeingRewritten(kind: String) throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        let path = ".buildrai/tracking/v1/config.json"
        let url = fixture.root.appending(path: path)
        let expected: TrackingResult.Status
        switch kind {
        case "disabled":
            try fixture.write(TrackingConfiguration(version: 1, scope: fixture.scope, enabled: false), path)
            expected = .disabled
        case "missing":
            try FileManager.default.removeItem(at: url)
            expected = .missingSetup
        case "incompatible":
            try fixture.write(TrackingConfiguration(version: 99, scope: fixture.scope, enabled: true), path)
            expected = .incompatibleVersion
        case "wrong-scope":
            let other = BridgeScope(repository: fixture.scope.repository,
                                    projectID: "other", rootPath: fixture.root.path)
            try fixture.write(TrackingConfiguration(version: 1, scope: other, enabled: true), path)
            expected = .invalidInput
        default:
            try Data("{}".utf8).write(to: url)
            expected = .invalidInput
        }
        let before = try? Data(contentsOf: url)
        #expect(throws: ExitCode(33)) { try fixture.record() }
        #expect(try fixture.result().status == expected)
        #expect(try !fixture.result().action.isEmpty)
        #expect((try? Data(contentsOf: url)) == before)
    }

    @Test func acknowledgementRejectsUnknownIDsWithoutRemovingKnownPendingRecords() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let record = try #require(fixture.result().records.first)
        #expect(throws: ExitCode(33)) { try fixture.acknowledge([record.receipt.recordID, "another-repository"]) }
        try fixture.replay()
        #expect(try fixture.result().records == [record])
    }

    @Test func capabilityAndRootCommandExposeOfflineRecording() throws {
        #expect(BuildrHooksCapabilities.current.reportingTracking.implementedOperations.contains(.recordCommit))
        #expect(BuildrHooksCapabilities.current.reportingTracking.implementedOperations.contains(.acknowledge))
        let command = try BuildrHooksCLICommand.parseAsRoot([
            "tracking", "record-commit", "--scope", "/scope.json", "--execution", "/execution.json"
        ])
        #expect(command is TrackingRecordCommitCommand)
    }

    @Test func interruptedAcknowledgementResponseCanBeRetriedWithoutResurrection() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let record = try #require(fixture.result().records.first)
        fixture.failAfterWrite = true
        #expect(throws: ExitCode(33)) { try fixture.acknowledge([record.receipt.recordID]) }
        fixture.failAfterWrite = false
        try fixture.acknowledge([record.receipt.recordID])
        try fixture.record()
        #expect(try fixture.result().status == .acknowledged)
        try fixture.replay()
        #expect(try fixture.result().records.isEmpty)
    }

    @Test func reportCleanupCannotEraseUnacknowledgedTracking() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let record = try #require(fixture.result().records.first)
        var command = try ReportResolveCommand.parse([
            "--scope", fixture.root.appending(path: "scope.json").path, "--query", "session-1"
        ])
        command.makeExecution = {
            var execution = ReportCommandExecution()
            execution.launch = { .unavailable }
            execution.output = { _ in }
            return execution
        }
        #expect(throws: ExitCode(32)) { try command.run() }
        try fixture.replay()
        #expect(try fixture.result().records == [record])
    }

    @Test func conflictingReplayCannotReplaceRetainedProvenance() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let record = try #require(fixture.result().records.first)
        var proof = fixture.proof
        proof.headAfter = String(repeating: "c", count: 40)
        try fixture.write(proof, "execution.json")
        #expect(throws: ExitCode(33)) { try fixture.record() }
        try fixture.replay()
        #expect(try fixture.result().records == [record])
    }

    @Test func symlinkedTrackingDirectoryCannotRedirectRecords() throws {
        let fixture = try TrackingFixture()
        let other = try TrackingFixture()
        defer { fixture.close(); other.close() }
        try FileManager.default.removeItem(at: fixture.root.appending(path: ".buildrai/tracking"))
        try FileManager.default.createSymbolicLink(
            at: fixture.root.appending(path: ".buildrai/tracking"),
            withDestinationURL: other.root.appending(path: ".buildrai/tracking")
        )
        #expect(throws: ExitCode(33)) { try fixture.record() }
        #expect(try fixture.result().status == .invalidInput)
        try other.replay()
        #expect(try other.result().records.isEmpty)
    }

    @Test func contentionReturnsBusyWhileAnotherRepositoryRemainsIndependent() throws {
        let fixture = try TrackingFixture()
        let other = try TrackingFixture()
        defer { fixture.close(); other.close() }
        fixture.beforeWrite = {
            #expect(throws: ExitCode(33)) { try fixture.replay() }
            #expect(try fixture.result().status == .busy)
            try other.record()
            #expect(try other.result().status == .queued)
        }
        try fixture.record()
        #expect(try fixture.result().status == .queued)
    }

    @Test func oversizedCompletionCannotClaimCapture() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try Data(repeating: 32, count: 4 * 1024 * 1024 + 1).write(
            to: fixture.root.appending(path: "execution.json")
        )
        #expect(throws: ExitCode(33)) { try fixture.record() }
        #expect(try fixture.result().status == .invalidInput)
        try fixture.replay()
        #expect(try fixture.result().records.isEmpty)
    }
}

final class TrackingFixture {
    let root: URL
    let scope: BridgeScope
    var output: [String] = []
    var failWrites = false
    var failAfterWrite = false
    var beforeWrite: (() throws -> Void)?

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        scope = BridgeScope(repository: .init(host: "github.com", owner: "owner", name: "repo"),
                            projectID: "project-1", rootPath: root.path)
        try write(scope, "scope.json")
        try FileManager.default.createDirectory(at: root.appending(path: ".buildrai/tracking/v1"),
                                                withIntermediateDirectories: true)
        try write(TrackingConfiguration(version: 1, scope: scope, enabled: true),
                  ".buildrai/tracking/v1/config.json")
        try write(proof, "execution.json")
    }

    var proof: TrackingCommitExecution {
        .init(invocationID: "invocation-1", session: .init(source: .codex, sessionID: "session-1"),
              repository: scope.repository, rootPath: root.path, argv: ["git", "commit", "-m", "change"],
              exitCode: 0, headBefore: String(repeating: "a", count: 40), headAfter: String(repeating: "b", count: 40))
    }

    func write(_ value: some Encodable, _ path: String) throws {
        try JSONEncoder().encode(value).write(to: root.appending(path: path), options: .atomic)
    }

    var execution: TrackingCommandExecution {
        var value = TrackingCommandExecution()
        value.now = { 100 }
        value.publish = { url, data in
            try self.beforeWrite?()
            if self.failWrites {
                throw CocoaError(.fileWriteOutOfSpace)
            }
            try data.write(to: url, options: .atomic)
            if self.failAfterWrite {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        value.output = { self.output.append($0) }
        return value
    }

    func record() throws {
        var command = try TrackingRecordCommitCommand.parse([
            "--scope", root.appending(path: "scope.json").path,
            "--execution", root.appending(path: "execution.json").path
        ])
        command.makeExecution = { self.execution }
        try command.run()
    }

    func replay() throws {
        var command = try TrackingReplayCommand.parse(["--scope", root.appending(path: "scope.json").path])
        command.makeExecution = { self.execution }
        try command.run()
    }

    func acknowledge(_ identifiers: [String]) throws {
        try write(BridgeAcknowledgement(recordIDs: identifiers), "ack.json")
        var command = try TrackingAcknowledgeCommand.parse([
            "--scope", root.appending(path: "scope.json").path,
            "--acknowledgement", root.appending(path: "ack.json").path
        ])
        command.makeExecution = { self.execution }
        try command.run()
    }

    func result() throws -> TrackingResult {
        try JSONDecoder().decode(TrackingResult.self, from: Data(#require(output.last).utf8))
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}
