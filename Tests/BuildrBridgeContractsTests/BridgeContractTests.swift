import BuildrBridgeContracts
import Foundation
import Testing

struct BridgeContractTests {
    @Test(arguments: [
        "acknowledgement-success",
        "cancel-success",
        "canonical-repository-invalid",
        "commit-abbreviated",
        "commit-success",
        "deadline-invalid",
        "discover-success",
        "error-ambiguous",
        "error-appUnavailable",
        "error-busy",
        "error-cancelled",
        "error-failed",
        "error-incompatibleVersion",
        "error-invalidInput",
        "error-launchFailed",
        "error-missingAccess",
        "error-missingSetup",
        "error-staleSnapshot",
        "error-timeout",
        "error-unresolved",
        "error-unsupported",
        "error-unusableEvidence",
        "evidence-from-future",
        "false-completeness",
        "finalize-success",
        "fork-source-mismatch",
        "generated-outcome-mismatch",
        "identity-empty",
        "malformed-version",
        "metric-negative",
        "missing-request-identity",
        "partial-without-disclosure",
        "pr-head-not-in-commits",
        "prepare-partial",
        "progress-collecting",
        "receipt-mismatch",
        "reference-stale",
        "request-mismatch",
        "resolve-ambiguous",
        "resolve-success",
        "response-operation",
        "response-scope",
        "response-version",
        "rewrite-empty",
        "rewrite-squash",
        "scope-mismatch",
        "session-source-mismatch",
        "snapshot-disclosure-stale",
        "snapshot-selection-mismatch",
        "snapshot-stale",
        "unknown-operation",
        "unknown-source",
        "version-unsupported"
    ])
    func sharedFixtureMatchesExpectedResult(name: String) throws {
        let data = try Data(contentsOf: BridgeCompatibilityFixtures.directory.appendingPathComponent(name + ".json"))
        let result = try BridgeCompatibilityFixtures.verify(data)
        #expect(result.matched, "\(name): \(String(describing: result.actualError))")
        let metadata = try JSONDecoder().decode(FixtureMetadata.self, from: data)
        if metadata.expectedError == nil {
            let fixture = try JSONDecoder().decode(BridgeFixture.self, from: data)
            let encoded = try JSONEncoder().encode(fixture.request)
            #expect(try JSONDecoder().decode(BridgeRequest.self, from: encoded) == fixture.request)
        }
    }

    private struct FixtureMetadata: Decodable {
        let expectedError: BridgeValidationError?
    }

    @Test
    func malformedOrUnknownWireValuesProduceTheSharedInvalidPayloadResult() throws {
        let url = BridgeCompatibilityFixtures.directory.appendingPathComponent("resolve-success.json")
        let data = try Data(contentsOf: url)
        var fixture = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        fixture["name"] = "unknown-operation"
        fixture["expectedError"] = "invalidPayload"
        var request = try #require(fixture["request"] as? [String: Any])
        request["body"] = ["futureOperation": ["_0": ["query": "session-1"]]]
        fixture["request"] = request
        let result = try BridgeCompatibilityFixtures.verify(JSONSerialization.data(withJSONObject: fixture))
        #expect(result.actualError == .invalidPayload)
        #expect(result.matched)
    }

    @Test
    func sharedCompatibilityCorpusPreservesPartialCoverageAndRejectsStaleReferences() throws {
        let results = try BridgeCompatibilityFixtures.verify()
        #expect(results.count == 53)
        for result in results {
            let expected = String(describing: result.expectedError)
            let actual = String(describing: result.actualError)
            #expect(result.matched, "\(result.name): expected \(expected), actual \(actual)")
        }
        let partial = try BridgeCompatibilityFixtures.preparedExample()
        #expect(partial.sessions[0].metrics.inputTokens == .unavailable("not reported"))
        #expect(partial.sessions[0].metrics.outputTokens == .available(0))
        #expect(partial.sessions[0].coverage.state == .partial)
        let good = try BridgeCompatibilityFixtures.finalizationExample()
        try BridgeValidator.validate(good, against: partial)
        let stale = BridgeGeneratedContent(snapshot: good.snapshot, summaries: [
            BridgeGeneratedSummary(session: partial.sessions[0].candidate.session, text: "Generated summary",
                                   evidenceIDs: ["missing-evidence"])
        ], groups: [])
        #expect(throws: BridgeValidationError.staleReference) {
            try BridgeValidator.validate(stale, against: partial)
        }
    }

    @Test
    func requestValidationRejectsUnsupportedVersionAndWrongRepository() throws {
        let repository = BridgeRepository(host: "github.com", owner: "example", name: "project")
        let scope = BridgeScope(repository: repository, projectID: "project-1", rootPath: "/workspace/project")
        let request = BridgeRequest(version: 2, requestID: "request-1", scope: scope,
                                    createdAt: 100, deadline: 200,
                                    body: .resolve(.init(query: "shared-session", source: nil)))
        #expect(throws: BridgeValidationError.incompatibleVersion) {
            try BridgeValidator.validate(request, expectedScope: scope)
        }
        let otherScope = BridgeScope(repository: .init(host: "github.com", owner: "example", name: "other"),
                                     projectID: "project-1", rootPath: "/workspace/project")
        let valid = BridgeRequest(version: 1, requestID: "request-1", scope: scope,
                                  createdAt: 100, deadline: 200,
                                  body: .resolve(.init(query: "shared-session", source: nil)))
        try BridgeValidator.validate(valid, expectedScope: scope)
        #expect(throws: BridgeValidationError.scopeMismatch) {
            try BridgeValidator.validate(valid, expectedScope: otherScope)
        }
    }
}
