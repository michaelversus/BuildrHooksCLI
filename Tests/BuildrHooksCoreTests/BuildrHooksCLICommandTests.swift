import Testing
@testable import BuildrHooksCLI

struct BuildrHooksCLICommandTests {
    @Test
    func configurationVersionMatchesSharedVersionConstant() {
        #expect(BuildrHooksCLICommand.configuration.version == version)
    }
}
