import BuildrBridgeContracts
import Foundation
import Testing

struct WorkflowTerminationTests {
    @Test func terminalMetadataIsVersionedAndBoundToTheOriginalDeadline() throws {
        let scope = BridgeScope(repository: .init(host: "github.com", owner: "owner", name: "repo"),
                                projectID: "project", rootPath: "/tmp/project")
        let request = BridgeRequest(version: 1, requestID: "request-1", scope: scope,
                                    createdAt: 100, deadline: 101, body: .resolve(.init(query: "private", source: nil)))
        let receipt = BridgeWorkflowTermination(requestID: "request-1", scope: scope,
                                                createdAt: 100, deadline: 101, code: .cancelled)
        try BridgeValidator.validate(receipt, for: request)
        let data = try JSONEncoder().encode(receipt)
        #expect(try !#require(String(data: data, encoding: .utf8)).contains("private"))
        #expect(try JSONDecoder().decode(BridgeWorkflowTermination.self, from: data) == receipt)
        let changed = BridgeWorkflowTermination(requestID: "request-1", scope: scope,
                                                createdAt: 100, deadline: 102, code: .cancelled)
        #expect(throws: BridgeValidationError.responseMismatch) {
            try BridgeValidator.validate(changed, for: request)
        }
    }
}
