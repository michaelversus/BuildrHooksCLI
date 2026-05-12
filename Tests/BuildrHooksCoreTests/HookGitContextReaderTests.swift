@testable import BuildrHooksCore
import CryptoKit
import Foundation
import Testing

struct HookGitContextReaderTests {
    @Test
    func readsBranchHeadRemoteUpstreamAndRepositoryFingerprint() throws {
        let repositoryRoot = try temporaryDirectory(named: "git-context")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        let gitDirectory = repositoryRoot.appending(path: ".git", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: gitDirectory.appending(path: "refs/heads", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )

        let headSHA = "0123456789abcdef0123456789abcdef01234567"
        try "ref: refs/heads/main\n".write(
            to: gitDirectory.appending(path: "HEAD"),
            atomically: true,
            encoding: .utf8
        )
        try "\(headSHA)\n".write(
            to: gitDirectory.appending(path: "refs/heads/main"),
            atomically: true,
            encoding: .utf8
        )
        try """
        [remote "origin"]
            url = git@github.com:example/project.git
        [branch "main"]
            remote = origin
            merge = refs/heads/main
        """.write(
            to: gitDirectory.appending(path: "config"),
            atomically: true,
            encoding: .utf8
        )

        let context = try #require(FileSystemHookGitContextReader().gitContext(repositoryRoot: repositoryRoot.path))

        #expect(context.headSHA == headSHA)
        #expect(context.branchName == "main")
        #expect(context.isDetachedHead == false)
        #expect(context.gitDirectoryPath == gitDirectory.resolvingSymlinksInPath().path)
        #expect(context.gitCommonDirectoryPath == gitDirectory.resolvingSymlinksInPath().path)
        #expect(context.remoteURL == "git@github.com:example/project.git")
        #expect(context.upstreamBranch == "origin/main")
        #expect(context.repositoryFingerprint == fingerprint(for: gitDirectory.path))
    }

    @Test
    func returnsNilOutsideGitRepository() throws {
        let repositoryRoot = try temporaryDirectory(named: "no-git-context")
        defer { try? FileManager.default.removeItem(at: repositoryRoot) }

        let context = FileSystemHookGitContextReader().gitContext(repositoryRoot: repositoryRoot.path)

        #expect(context == nil)
    }

    private func temporaryDirectory(named name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "BuildrHooksCLI-\(name)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func fingerprint(for path: String) -> String {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
