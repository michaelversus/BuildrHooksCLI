import ArgumentParser
@testable import BuildrHooksCLI
import BuildrHooksCore
import Foundation
import Testing

struct ClaudeUsageDeliveryTests {
    @Test func legacyCapabilitiesWithoutCallbackFieldsRemainReadableWithoutInventingSupport() throws {
        var object = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(BuildrHooksCapabilities.current)
        ) as? [String: Any])
        object.removeValue(forKey: "accountUsageCaptureProviders")
        object.removeValue(forKey: "accountUsageSetupProviders")
        object["accountUsageClearProviders"] = ["codex"]
        object["accountUsageSchemaVersions"] = [1]
        let legacy = try JSONDecoder().decode(BuildrHooksCapabilities.self,
                                              from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.accountUsageCaptureProviders.isEmpty && legacy.accountUsageSetupProviders.isEmpty)
        #expect(legacy.accountUsageClearProviders == [.codex] && legacy.accountUsageSchemaVersions == [1])
    }

    @Test func capabilitiesDistinguishCallbackSupportFromNetworkCollection() throws {
        let capabilities = BuildrHooksCapabilities.current
        #expect(capabilities.accountUsageClearProviders == [.codex, .claude])
        #expect(capabilities.accountUsageSchemaVersions == [1, 2])
        #expect(capabilities.accountUsageRefreshProviders == [.codex])
        #expect(capabilities.accountUsageWatchProviders == [.codex])
        #expect(capabilities.accountUsageServiceProviders == [.codex])
        try UsageClearCommand.parse(["--provider", "claude"]).validate()
        #expect(throws: (any Error).self) { try UsageRefreshCommand.parse(["--provider", "claude"]).validate() }
        #expect(throws: (any Error).self) { try UsageWatchCommand.parse(["--provider", "claude"]).validate() }
    }

    @Test func additiveCapabilitiesExposeExplicitSetupAndCaptureWithoutChangingLegacyEnvelope() throws {
        let data = try JSONEncoder().encode(BuildrHooksCapabilities.current)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        #expect(object["accountUsageCaptureProviders"] as? [String] == ["claude"])
        #expect(object["accountUsageSetupProviders"] as? [String] == ["claude"])
        for arguments in [["claude", "statusline", "setup"], ["claude", "statusline", "setup", "--apply"],
                          ["claude", "statusline", "setup", "--repair"], ["claude", "statusline", "status"],
                          ["claude", "statusline", "remove"], ["claude", "statusline", "remove", "--apply"],
                          ["claude", "statusline", "capture", "--json"], ["usage", "clear", "--provider", "claude"]] {
            _ = try BuildrHooksCLICommand.parseAsRoot(arguments)
        }
    }
}
