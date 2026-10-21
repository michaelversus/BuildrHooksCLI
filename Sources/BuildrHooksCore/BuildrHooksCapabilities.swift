import Foundation

public struct BuildrHooksCapabilities: Codable, Equatable, Sendable {
    public let version: Int
    public let agents: [HookAgentKind]
    public let lifecycleEvents: [HookEventKind]
    public let claudeDesktopTranscriptSurfaceResolver: Bool
    public let toolStartEvents: [HookAgentKind]

    public let accountUsageRefreshProviders: [UsageProvider]
    public let accountUsageClearProviders: [UsageProvider]
    public let accountUsageWatchProviders: [UsageProvider]
    public let accountUsageServiceProviders: [UsageProvider]
    public let accountUsageCaptureProviders: [UsageProvider]
    public let accountUsageSetupProviders: [UsageProvider]
    public let accountUsageSchemaVersions: [Int]

    public static let current = BuildrHooksCapabilities(
        version: 1,
        agents: [.codex, .claude],
        lifecycleEvents: [.sessionStart, .promptSubmit, .stop],
        claudeDesktopTranscriptSurfaceResolver: true,
        toolStartEvents: [.codex, .claude],
        accountUsageRefreshProviders: [.codex],
        accountUsageClearProviders: [.codex, .claude],
        accountUsageWatchProviders: [.codex],
        accountUsageServiceProviders: [.codex],
        accountUsageCaptureProviders: [.claude],
        accountUsageSetupProviders: [.claude],
        accountUsageSchemaVersions: [1, 2]
    )
}

public extension BuildrHooksCapabilities {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        agents = try values.decode([HookAgentKind].self, forKey: .agents)
        lifecycleEvents = try values.decode([HookEventKind].self, forKey: .lifecycleEvents)
        claudeDesktopTranscriptSurfaceResolver = try values.decode(Bool.self,
                                                                   forKey: .claudeDesktopTranscriptSurfaceResolver)
        toolStartEvents = try values.decode([HookAgentKind].self, forKey: .toolStartEvents)
        accountUsageRefreshProviders = try values.decode([UsageProvider].self, forKey: .accountUsageRefreshProviders)
        accountUsageClearProviders = try values.decode([UsageProvider].self, forKey: .accountUsageClearProviders)
        accountUsageWatchProviders = try values.decode([UsageProvider].self, forKey: .accountUsageWatchProviders)
        accountUsageServiceProviders = try values.decode([UsageProvider].self, forKey: .accountUsageServiceProviders)
        accountUsageCaptureProviders = try values.decodeIfPresent([UsageProvider].self,
                                                                  forKey: .accountUsageCaptureProviders) ?? []
        accountUsageSetupProviders = try values.decodeIfPresent([UsageProvider].self,
                                                                forKey: .accountUsageSetupProviders) ?? []
        accountUsageSchemaVersions = try values.decode([Int].self, forKey: .accountUsageSchemaVersions)
    }
}
