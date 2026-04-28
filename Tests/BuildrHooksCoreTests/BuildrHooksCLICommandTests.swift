@testable import BuildrHooksCLI
import Testing

struct BuildrHooksCLICommandTests {
    @Test
    func configurationVersionMatchesSharedVersionConstant() {
        #expect(BuildrHooksCLICommand.configuration.version == version)
    }
}
