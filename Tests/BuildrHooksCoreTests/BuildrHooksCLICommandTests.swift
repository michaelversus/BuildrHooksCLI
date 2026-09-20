@testable import BuildrHooksCLI
import Testing

struct BuildrHooksCLICommandTests {
    @Test
    func configurationVersionMatchesSharedVersionConstant() {
        #expect(BuildrHooksCLICommand.configuration.version == version)
    }

    @Test
    func hookCommandsRelayTheirDeclaredAgentAndLifecycleKinds() throws {
        #expect(CodexSessionStartCommand.hookAgentKind == .codex)
        #expect(CodexSessionStartCommand.hookEventKind == .sessionStart)
        #expect(CodexPromptSubmitCommand.hookAgentKind == .codex)
        #expect(CodexPromptSubmitCommand.hookEventKind == .promptSubmit)
        #expect(CodexStopCommand.hookAgentKind == .codex)
        #expect(CodexStopCommand.hookEventKind == .stop)
        #expect(ClaudeSessionStartCommand.hookAgentKind == .claude)
        #expect(ClaudeSessionStartCommand.hookEventKind == .sessionStart)
        #expect(ClaudePromptSubmitCommand.hookAgentKind == .claude)
        #expect(ClaudePromptSubmitCommand.hookEventKind == .promptSubmit)
        #expect(ClaudeStopCommand.hookAgentKind == .claude)
        #expect(ClaudeStopCommand.hookEventKind == .stop)

        var codexSessionStart = try CodexSessionStartCommand.parse([])
        var codexPromptSubmit = try CodexPromptSubmitCommand.parse([])
        var codexStop = try CodexStopCommand.parse([])
        var claudeSessionStart = try ClaudeSessionStartCommand.parse([])
        var claudePromptSubmit = try ClaudePromptSubmitCommand.parse([])
        var claudeStop = try ClaudeStopCommand.parse([])
        try codexSessionStart.run()
        try codexPromptSubmit.run()
        try codexStop.run()
        try claudeSessionStart.run()
        try claudePromptSubmit.run()
        try claudeStop.run()
    }

    @Test
    func capabilitiesCommandEmitsTextAndSortedJSON() throws {
        let textCommand = try CapabilitiesCommand.parse([])
        try textCommand.run()

        let jsonCommand = try CapabilitiesCommand.parse(["--json"])
        try jsonCommand.run()
    }
}
