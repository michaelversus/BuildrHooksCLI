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
    public let accountUsageSchemaVersions: [Int]

    public static let current = BuildrHooksCapabilities(
        version: 1,
        agents: [.codex, .claude],
        lifecycleEvents: [.sessionStart, .promptSubmit, .stop],
        claudeDesktopTranscriptSurfaceResolver: true,
        toolStartEvents: [.codex, .claude],
        accountUsageRefreshProviders: [.codex],
        accountUsageClearProviders: [.codex],
        accountUsageWatchProviders: [.codex],
        accountUsageSchemaVersions: [1]
    )
}
