@testable import BuildrHooksCore
import Foundation
import Testing

struct RepositoryRootLocatorTests {
    @Test
    func findsNearestAncestorContainingGitMarker() throws {
        let repositoryRoot = try temporaryDirectory(named: "repo-root")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        let nestedDirectory = repositoryRoot
            .appending(path: "Sources/Feature", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nestedDirectory, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: repositoryRoot.appending(path: ".git").path, contents: Data())

        let located = RepositoryRootLocator().repositoryRoot(startingAt: nestedDirectory.path)

        #expect(located.path == repositoryRoot.path)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BuildrHooksCLI-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
