import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import Foundation
import Testing

struct TrackingRewriteCommandTests {
    @Test func amendMappingIsDurableWithoutOpeningTheApp() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        try fixture.writeRewrite()
        let parsed = try BuildrHooksCLICommand.parseAsRoot([
            "tracking", "record-rewrite", "--scope", fixture.root.appending(path: "scope.json").path,
            "--execution", fixture.root.appending(path: "rewrite.json").path
        ])
        var command = try #require(parsed as? TrackingRecordRewriteCommand)
        command.makeExecution = { fixture.execution }
        try command.run()
        try fixture.replay()
        let json = try fixture.replayJSON()
        let rewrites = try #require(json["rewrites"] as? [[String: Any]])
        #expect(rewrites.count == 1)
        let receipt = try #require(rewrites.first?["receipt"] as? [String: Any])
        #expect(receipt["kind"] as? String == "amend")
        let mappings = try #require(receipt["mappings"] as? [[String: String]])
        #expect(mappings == [["original": String(repeating: "b", count: 40),
                              "replacement": String(repeating: "c", count: 40)]])
        #expect(try fixture.result().records.first?.receipt.session.sessionID == "session-1")
    }

    @Test func rewriteAcknowledgementSurvivesInterruptionWithoutLosingPendingCommits() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let commit = try #require(fixture.result().records.first)
        try fixture.writeRewrite()
        try fixture.recordRewrite()
        let rewrite = try #require(fixture.rewriteReceipts().first)
        let identifier = try #require(rewrite["recordID"] as? String)
        try fixture.replay()
        #expect(try fixture.rewriteReceipts().count == 1)
        // App ingestion succeeded; acknowledgement response is interrupted after atomic persistence.
        fixture.failAfterWrite = true
        #expect(throws: ExitCode(33)) { try fixture.acknowledge([identifier]) }
        fixture.failAfterWrite = false
        try fixture.acknowledge([identifier])
        try fixture.recordRewrite()
        #expect(try fixture.result().status == .acknowledged)
        try fixture.replay()
        #expect(try fixture.rewriteReceipts().isEmpty)
        #expect(try fixture.result().records == [commit])
    }

    @Test func unsupportedDeletionCannotClaimARewriteOrDiscardPendingRecords() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let commit = try #require(fixture.result().records.first)
        try fixture.writeRewrite(pairs: [["original": String(repeating: "b", count: 40),
                                          "replacement": String(repeating: "0", count: 40)]])
        #expect(throws: ExitCode(33)) { try fixture.recordRewrite() }
        #expect(try fixture.result().status == .invalidInput)
        #expect(try !fixture.result().action.isEmpty)
        try fixture.replay()
        #expect(try fixture.result().records == [commit])
        #expect(try fixture.rewriteReceipts().isEmpty)
    }

    @Test func corruptedRetainedRewriteCannotBeReplayedAsTrustedProvenance() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.writeRewrite()
        try fixture.recordRewrite()
        // Simulate damage at the durable filesystem boundary.
        let ledgerURL = fixture.root.appending(path: ".buildrai/tracking/v1/records.json")
        let data = try Data(contentsOf: ledgerURL)
        let text = try #require(String(data: data, encoding: .utf8))
        let damaged = text.replacingOccurrences(of: "rewrite-", with: "damaged-")
        try Data(damaged.utf8).write(to: ledgerURL)
        #expect(throws: ExitCode(33)) { try fixture.replay() }
        #expect(try fixture.result().status == .failed)
        #expect(try fixture.rewriteReceipts().isEmpty)
        #expect(try Data(contentsOf: ledgerURL) == Data(damaged.utf8))
    }

    @Test func olderCommitOnlyResultsRemainReadableWithoutInventingRewriteCoverage() throws {
        let data = Data(#"{"version":1,"status":"replay","action":"Retain receipts","records":[]}"#.utf8)
        let result = try JSONDecoder().decode(TrackingResult.self, from: data)
        #expect(result.records.isEmpty)
        #expect(result.rewrites.isEmpty)
        #expect(result.status == .replay)
    }

    @Test func squashAndLaterChainRetainBothSourcesAndStableDuplicateIdentities() throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let first = try #require(fixture.result().records.first)
        var proof = fixture.proof
        proof.invocationID = "invocation-2"
        proof.session = .init(source: .claude, sessionID: "session-2")
        proof.headBefore = String(repeating: "b", count: 40)
        proof.headAfter = String(repeating: "c", count: 40)
        try fixture.write(proof, "execution.json")
        try fixture.record()
        let second = try #require(fixture.result().records.first)
        let pairs = [
            ["original": String(repeating: "b", count: 40), "replacement": String(repeating: "d", count: 40)],
            ["original": String(repeating: "c", count: 40), "replacement": String(repeating: "d", count: 40)]
        ]
        try fixture.writeRewrite(kind: "rebase", pairs: pairs)
        try fixture.recordRewrite()
        let squash = try #require(fixture.result().rewrites.first)
        try fixture.recordRewrite()
        #expect(try fixture.result().rewrites == [squash])
        try fixture.writeRewrite(invocation: "rewrite-2", kind: "explicit", pairs: [
            ["original": String(repeating: "d", count: 40), "replacement": String(repeating: "e", count: 40)]
        ])
        try fixture.recordRewrite()
        let chain = try #require(fixture.result().rewrites.first)
        try fixture.replay()
        #expect(try fixture.result().records == [first, second])
        #expect(try fixture.result().rewrites == [squash, chain])
        #expect(squash.receipt.mappings.map(\.replacement)
            == Array(repeating: String(repeating: "d", count: 40), count: 2))
        #expect(chain.receipt.recordID != squash.receipt.recordID)
        #expect(squash.recordedAt == 100)
        // Conflicting reuse and unknown acknowledgement must be atomic.
        try fixture.writeRewrite(kind: "amend")
        #expect(throws: ExitCode(33)) { try fixture.recordRewrite() }
        #expect(throws: ExitCode(33)) { try fixture.acknowledge([squash.receipt.recordID, "unknown"]) }
        try fixture.replay()
        #expect(try fixture.result().rewrites == [squash, chain])
        try fixture.acknowledge([first.receipt.recordID, squash.receipt.recordID])
        try fixture.replay()
        #expect(try fixture.result().records == [second])
        #expect(try fixture.result().rewrites == [chain])
    }

    @Test(arguments: ["amend", "rebase"])
    func unavailableRecordingAndReportCleanupPreserveBothQueues(kind: String) throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.record()
        let commit = try #require(fixture.result().records.first)
        try fixture.writeRewrite(kind: kind)
        try fixture.recordRewrite()
        let rewrite = try #require(fixture.result().rewrites.first)
        try fixture.writeRewrite(invocation: "rewrite-2", kind: kind)
        fixture.failWrites = true
        #expect(throws: ExitCode(33)) { try fixture.recordRewrite() }
        #expect(try fixture.result().status == .failed)
        #expect(try fixture.result().rewrites.isEmpty)
        #expect(throws: ExitCode(33)) { try fixture.acknowledge([rewrite.receipt.recordID]) }
        fixture.failWrites = false
        var report = try ReportResolveCommand.parse([
            "--scope", fixture.root.appending(path: "scope.json").path, "--query", "session-1"
        ])
        report.makeExecution = {
            var execution = ReportCommandExecution()
            execution.launch = { .unavailable }
            execution.output = { _ in }
            return execution
        }
        #expect(throws: ExitCode(32)) { try report.run() }
        try fixture.replay()
        #expect(try fixture.result().records == [commit])
        #expect(try fixture.result().rewrites == [rewrite])
        fixture.failAfterWrite = true
        #expect(throws: ExitCode(33)) { try fixture.recordRewrite() }
        fixture.failAfterWrite = false
        try fixture.recordRewrite()
        try fixture.replay()
        #expect(try fixture.result().rewrites.count == 2)
        #expect(try fixture.result().records == [commit])
    }

    @Test(arguments: ["empty", "duplicate", "partial", "kind", "abbreviated", "identity", "scope", "mixed", "self"])
    func malformedBatchIsRejectedAsAWhole(kind: String) throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        try fixture.writeRewrite()
        try fixture.recordRewrite()
        let retained = try #require(fixture.result().rewrites.first)
        try fixture.writeRewrite(invocation: "rewrite-2")
        let url = fixture.root.appending(path: "rewrite.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let original = String(repeating: "b", count: 40)
        let replacement = String(repeating: "c", count: 40)
        let pair = ["original": original, "replacement": replacement]
        switch kind {
        case "empty": json["mappings"] = []
        case "duplicate": json["mappings"] = [pair, pair]
        case "partial": json["mappings"] = [pair, ["original": String(repeating: "d", count: 40)]]
        case "kind": json["kind"] = "similar-patches"
        case "abbreviated": json["mappings"] = [["original": "abcdef0", "replacement": replacement]]
        case "identity": json["invocationID"] = ""
        case "scope": json["rootPath"] = "/another-project"
        case "mixed": json["mappings"] = [["original": String(repeating: "a", count: 64),
                                           "replacement": replacement]]
        default: json["mappings"] = [["original": original, "replacement": original]]
        }
        try JSONSerialization.data(withJSONObject: json).write(to: url)
        #expect(throws: ExitCode(33)) { try fixture.recordRewrite() }
        #expect(try fixture.result().status == .invalidInput)
        #expect(try !fixture.result().action.isEmpty)
        try fixture.replay()
        #expect(try fixture.result().rewrites == [retained])
    }

    @Test func sameInvocationIdentityInAnotherScopeCannotAliasAReceipt() throws {
        let first = try TrackingFixture()
        let second = try TrackingFixture()
        defer { first.close(); second.close() }
        try first.writeRewrite()
        try second.writeRewrite()
        try first.recordRewrite()
        try second.recordRewrite()
        let one = try #require(first.result().rewrites.first)
        let two = try #require(second.result().rewrites.first)
        #expect(one.receipt.recordID != two.receipt.recordID)
        #expect(throws: ExitCode(33)) { try second.acknowledge([one.receipt.recordID]) }
        try second.replay()
        #expect(try second.result().rewrites == [two])
    }
}

extension TrackingFixture {
    func recordRewrite() throws {
        var command = try TrackingRecordRewriteCommand.parse([
            "--scope", root.appending(path: "scope.json").path,
            "--execution", root.appending(path: "rewrite.json").path
        ])
        command.makeExecution = { self.execution }
        try command.run()
    }

    func rewriteReceipts() throws -> [[String: Any]] {
        let json = try replayJSON()
        let rewrites = try #require(json["rewrites"] as? [[String: Any]])
        return try rewrites.map { try #require($0["receipt"] as? [String: Any]) }
    }

    func writeRewrite(invocation: String = "rewrite-1", kind: String = "amend",
                      pairs: [[String: String]]? = nil) throws {
        let value: [String: Any] = [
            "invocationID": invocation, "repository": ["host": "github.com", "owner": "owner", "name": "repo"],
            "rootPath": root.path, "kind": kind,
            "mappings": pairs ?? [["original": String(repeating: "b", count: 40),
                                   "replacement": String(repeating: "c", count: 40)]]
        ]
        try JSONSerialization.data(withJSONObject: value).write(to: root.appending(path: "rewrite.json"))
    }

    func replayJSON() throws -> [String: Any] {
        let line = try #require(output.last)
        return try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}
