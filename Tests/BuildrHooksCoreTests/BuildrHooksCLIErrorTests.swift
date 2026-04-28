@testable import BuildrHooksCore
import Testing

struct BuildrHooksCLIErrorTests {
    struct DescriptionCase: CustomTestStringConvertible {
        let description: String
        let error: BuildrHooksCLIError
        let expectedDescription: String

        var testDescription: String {
            description
        }
    }

    @Test(arguments: descriptionCases)
    func errorDescriptionMatchesCase(testCase: DescriptionCase) {
        #expect(testCase.error.errorDescription == testCase.expectedDescription)
        #expect(testCase.error.localizedDescription == testCase.expectedDescription)
    }

    @Test
    func equatablePreservesAssociatedValues() {
        #expect(
            BuildrHooksCLIError.unsupportedCommand(["codex", "extra"]) ==
                .unsupportedCommand(["codex", "extra"])
        )
        #expect(
            BuildrHooksCLIError.unsupportedCommand(["codex", "extra"]) !=
                .unsupportedCommand(["codex"])
        )
        #expect(
            BuildrHooksCLIError.unsupportedAgent("claude") ==
                .unsupportedAgent("claude")
        )
        #expect(
            BuildrHooksCLIError.unsupportedAgent("claude") !=
                .unsupportedAgent("codex")
        )
        #expect(
            BuildrHooksCLIError.unsupportedEvent("prompt-submit") ==
                .unsupportedEvent("prompt-submit")
        )
        #expect(
            BuildrHooksCLIError.unsupportedEvent("prompt-submit") !=
                .unsupportedEvent("session-start")
        )
        #expect(
            BuildrHooksCLIError.unsupportedCommand(["codex", "prompt-submit"]) !=
                .unsupportedAgent("codex")
        )
    }

    static let descriptionCases: [DescriptionCase] = [
        DescriptionCase(
            description: "unsupported command joins all provided components",
            error: .unsupportedCommand(["codex", "session-start", "extra"]),
            expectedDescription: "Unsupported BuildrHooksCLI command: codex session-start extra"
        ),
        DescriptionCase(
            description: "unsupported agent includes the agent name",
            error: .unsupportedAgent("claude"),
            expectedDescription: "Unsupported BuildrHooksCLI agent: claude"
        ),
        DescriptionCase(
            description: "unsupported event includes the event name",
            error: .unsupportedEvent("unknown-event"),
            expectedDescription: "Unsupported BuildrHooksCLI event: unknown-event"
        )
    ]
}
