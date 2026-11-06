import ArgumentParser
import BuildrBridgeContracts
@testable import BuildrHooksCLI
import BuildrHooksCore
import Foundation
import Testing

struct BridgeCapabilityTests {
    @Test
    func olderCapabilitiesKeepExistingBehaviorWithoutInventingBridgeSupport() throws {
        let data = try JSONEncoder().encode(BuildrHooksCapabilities.current)
        var json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "reportingTracking")
        let older = try JSONDecoder().decode(BuildrHooksCapabilities.self,
                                             from: JSONSerialization.data(withJSONObject: json))
        #expect(older.agents == [.codex, .claude])
        #expect(older.accountUsageSchemaVersions == [1, 2])
        #expect(older.reportingTracking.protocolVersions.isEmpty)
        #expect(older.reportingTracking.implementedOperations.isEmpty)
        #expect(older.reportingTracking.negotiate(version: 1, operation: "discover").status == .incompatible)
    }

    @Test
    func negotiationCommandRejectsIncompatibleAndUnimplementedOperationsWithActionableJSON() throws {
        let output = CoordinationCapture()
        var command = try CapabilitiesCommand.parse(["--json", "--protocol-version", "2", "--operation", "discover"])
        command.output = { output.append($0) }
        #expect(throws: ExitCode(30)) { try command.run() }
        let result = try JSONDecoder().decode(BridgeReadiness.self, from: Data(#require(output.output.last).utf8))
        #expect(result.status == .incompatible)
        #expect(!result.action.isEmpty)
        var unsupported = try CapabilitiesCommand.parse([
            "--json", "--protocol-version", "1", "--operation", "finalize"
        ])
        unsupported.output = { output.append($0) }
        #expect(throws: ExitCode(31)) { try unsupported.run() }
        let second = try JSONDecoder().decode(BridgeReadiness.self, from: Data(#require(output.output.last).utf8))
        #expect(second.status == .unsupported)
        #expect(throws: (any Error).self) {
            try CapabilitiesCommand.parse(["--protocol-version", "1"]).validate()
        }
    }

    @Test
    func capabilitiesDistinguishSchemasFromExecutableOperations() throws {
        let data = try JSONEncoder().encode(BuildrHooksCapabilities.current)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bridge = try #require(json["reportingTracking"] as? [String: Any])
        #expect(bridge["protocolVersions"] as? [Int] == [1])
        #expect(bridge["implementedOperations"] as? [String] == ["discover", "resolve", "prepare"])
    }
}
