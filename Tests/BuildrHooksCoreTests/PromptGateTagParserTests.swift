@testable import BuildrHooksCore
import Testing

struct PromptGateTagParserTests {
    @Test
    func recognizesStandaloneControlLineAndRemovesIt() throws {
        let parsed = try #require(try PromptGateTagParser().parse("""
        Before
          #BuildrAI-Eval
        After
        """))

        #expect(parsed.originalPrompt.contains("#BuildrAI-Eval"))
        #expect(parsed.evaluationPrompt == """
        Before
        After
        """)
    }

    @Test
    func ignoresControlTagInProse() throws {
        let parsed = try PromptGateTagParser().parse("Please mention #BuildrAI-Eval in docs.")
        #expect(parsed == nil)
    }

    @Test
    func ignoresControlTagInsideFence() throws {
        let parsed = try PromptGateTagParser().parse("""
        ```text
        #BuildrAI-Eval
        ```
        """)
        #expect(parsed == nil)
    }

    @Test
    func removesMultipleControlLines() throws {
        let parsed = try #require(try PromptGateTagParser().parse("""
        #BuildrAI-Eval
        Ship this.
        #BuildrAI-Eval
        """))

        #expect(parsed.evaluationPrompt == "Ship this.")
    }

    @Test
    func emptyEvaluationPromptFails() {
        do {
            _ = try PromptGateTagParser().parse("  #BuildrAI-Eval  ")
            Issue.record("Expected empty prompt failure.")
        } catch let error as PromptGateTagParserError {
            #expect(error == .emptyEvaluationPrompt)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
