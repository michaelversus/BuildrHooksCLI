import Foundation

public struct BuildrHooksCapabilities: Codable, Equatable, Sendable {
    public let version: Int
    public let agents: [HookAgentKind]
    public let lifecycleEvents: [HookEventKind]
    public let claudeDesktopTranscriptSurfaceResolver: Bool

    public static let current = BuildrHooksCapabilities(
        version: 1,
        agents: [.codex, .claude],
        lifecycleEvents: [.sessionStart, .promptSubmit, .stop],
        claudeDesktopTranscriptSurfaceResolver: true
    )
}
