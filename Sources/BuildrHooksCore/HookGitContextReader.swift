import CryptoKit
import Foundation

public protocol HookGitContextReading: Sendable {
    func gitContext(repositoryRoot: String) -> HookGitContext?
}

public struct FileSystemHookGitContextReader: HookGitContextReading {
    public init() {}

    public func gitContext(repositoryRoot: String) -> HookGitContext? {
        let repositoryURL = URL(fileURLWithPath: repositoryRoot, isDirectory: true).standardizedFileURL
        guard let gitDirectoryURL = resolveGitDirectoryURL(repositoryURL: repositoryURL) else {
            return nil
        }

        let gitCommonDirectoryURL = resolveGitCommonDirectoryURL(gitDirectoryURL: gitDirectoryURL)
        let head = resolveHead(gitDirectoryURL: gitDirectoryURL, gitCommonDirectoryURL: gitCommonDirectoryURL)
        let config = readConfig(gitDirectoryURL: gitDirectoryURL, gitCommonDirectoryURL: gitCommonDirectoryURL)
        let upstreamBranch = upstreamBranch(
            branchName: head.branchName,
            config: config
        )
        let remoteURL = remoteURL(
            branchName: head.branchName,
            config: config
        )

        return HookGitContext(
            headSHA: head.sha,
            branchName: head.branchName,
            isDetachedHead: head.isDetached,
            gitDirectoryPath: gitDirectoryURL.resolvingSymlinksInPath().path,
            gitCommonDirectoryPath: gitCommonDirectoryURL.resolvingSymlinksInPath().path,
            remoteURL: remoteURL,
            upstreamBranch: upstreamBranch,
            repositoryFingerprint: repositoryFingerprint(
                repoRoot: repositoryURL.path,
                gitCommonDirectoryPath: gitCommonDirectoryURL.path
            )
        )
    }
}

private extension FileSystemHookGitContextReader {
    struct HeadState {
        let sha: String?
        let branchName: String?
        let isDetached: Bool
    }

    func resolveGitDirectoryURL(repositoryURL: URL) -> URL? {
        let dotGitURL = repositoryURL.appending(path: ".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGitURL.path, isDirectory: &isDirectory) else {
            return nil
        }
        if isDirectory.boolValue {
            return dotGitURL.standardizedFileURL
        }

        guard let body = try? String(contentsOf: dotGitURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            body.hasPrefix("gitdir:")
        else {
            return nil
        }

        let rawPath = body.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard rawPath.isEmpty == false else { return nil }
        if rawPath.hasPrefix("/") {
            return URL(fileURLWithPath: rawPath, isDirectory: true).standardizedFileURL
        }
        return repositoryURL.appending(path: rawPath, directoryHint: .isDirectory).standardizedFileURL
    }

    func resolveGitCommonDirectoryURL(gitDirectoryURL: URL) -> URL {
        let commonDirURL = gitDirectoryURL.appending(path: "commondir")
        guard let rawCommonDir = try? String(contentsOf: commonDirURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            rawCommonDir.isEmpty == false
        else {
            return gitDirectoryURL.standardizedFileURL
        }

        if rawCommonDir.hasPrefix("/") {
            return URL(fileURLWithPath: rawCommonDir, isDirectory: true).standardizedFileURL
        }
        return gitDirectoryURL.appending(path: rawCommonDir, directoryHint: .isDirectory).standardizedFileURL
    }

    func resolveHead(gitDirectoryURL: URL, gitCommonDirectoryURL: URL) -> HeadState {
        let headURL = gitDirectoryURL.appending(path: "HEAD")
        guard let head = try? String(contentsOf: headURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
            head.isEmpty == false
        else {
            return HeadState(sha: nil, branchName: nil, isDetached: false)
        }

        if head.hasPrefix("ref:") {
            let refName = head.dropFirst("ref:".count).trimmingCharacters(in: .whitespacesAndNewlines)
            return HeadState(
                sha: resolveRef(
                    refName,
                    gitDirectoryURL: gitDirectoryURL,
                    gitCommonDirectoryURL: gitCommonDirectoryURL
                ),
                branchName: branchName(from: refName),
                isDetached: false
            )
        }

        return HeadState(sha: head, branchName: nil, isDetached: true)
    }

    func resolveRef(_ refName: String, gitDirectoryURL: URL, gitCommonDirectoryURL: URL) -> String? {
        let looseRefURLs = [
            gitDirectoryURL.appending(path: refName),
            gitCommonDirectoryURL.appending(path: refName)
        ]

        for url in looseRefURLs {
            if let sha = try? String(contentsOf: url, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines),
                sha.isEmpty == false {
                return sha
            }
        }

        return resolvePackedRef(refName, gitCommonDirectoryURL: gitCommonDirectoryURL)
            ?? resolvePackedRef(refName, gitCommonDirectoryURL: gitDirectoryURL)
    }

    func resolvePackedRef(_ refName: String, gitCommonDirectoryURL: URL) -> String? {
        let packedRefsURL = gitCommonDirectoryURL.appending(path: "packed-refs")
        guard let packedRefs = try? String(contentsOf: packedRefsURL, encoding: .utf8) else {
            return nil
        }

        for line in packedRefs.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false,
                  trimmed.hasPrefix("#") == false,
                  trimmed.hasPrefix("^") == false
            else { continue }

            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] == refName else { continue }
            return parts[0]
        }

        return nil
    }

    func branchName(from refName: String) -> String? {
        let prefix = "refs/heads/"
        guard refName.hasPrefix(prefix) else { return nil }
        return String(refName.dropFirst(prefix.count))
    }

    func readConfig(gitDirectoryURL: URL, gitCommonDirectoryURL: URL) -> String {
        var config = ""
        for url in [gitCommonDirectoryURL.appending(path: "config"), gitDirectoryURL.appending(path: "config")] {
            guard let body = try? String(contentsOf: url, encoding: .utf8), body.isEmpty == false else {
                continue
            }
            config += "\n\(body)"
        }
        return config
    }

    func remoteURL(branchName: String?, config: String) -> String? {
        if let branchName,
           let branchRemote = configValue("remote", section: #"branch "\#(branchName)""#, config: config),
           let url = configValue("url", section: #"remote "\#(branchRemote)""#, config: config) {
            return url
        }

        if let originURL = configValue("url", section: #"remote "origin""#, config: config) {
            return originURL
        }

        return firstConfigValue("url", sectionPrefix: "remote ", config: config)
    }

    func upstreamBranch(branchName: String?, config: String) -> String? {
        guard let branchName,
              let merge = configValue("merge", section: #"branch "\#(branchName)""#, config: config)
        else {
            return nil
        }

        let shortMerge = self.branchName(from: merge) ?? merge
        guard let remote = configValue("remote", section: #"branch "\#(branchName)""#, config: config),
              remote.isEmpty == false,
              remote != "."
        else {
            return shortMerge
        }
        return "\(remote)/\(shortMerge)"
    }

    func configValue(_ key: String, section: String, config: String) -> String? {
        var currentSection: String?
        for line in config.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsedSection = sectionName(from: trimmed) {
                currentSection = parsedSection
                continue
            }
            guard currentSection == section else { continue }
            guard let value = keyValue(key, from: trimmed) else { continue }
            return value
        }
        return nil
    }

    func firstConfigValue(_ key: String, sectionPrefix: String, config: String) -> String? {
        var currentSection: String?
        for line in config.split(whereSeparator: \.isNewline).map(String.init) {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let parsedSection = sectionName(from: trimmed) {
                currentSection = parsedSection
                continue
            }
            guard let currentSection,
                  currentSection.hasPrefix(sectionPrefix),
                  let value = keyValue(key, from: trimmed)
            else { continue }
            return value
        }
        return nil
    }

    func sectionName(from line: String) -> String? {
        guard line.hasPrefix("["), line.hasSuffix("]") else { return nil }
        return String(line.dropFirst().dropLast())
    }

    func keyValue(_ expectedKey: String, from line: String) -> String? {
        let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
        guard parts.count == 2,
              parts[0].trimmingCharacters(in: .whitespacesAndNewlines) == expectedKey
        else {
            return nil
        }
        return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func repositoryFingerprint(repoRoot: String, gitCommonDirectoryPath: String?) -> String {
        let path = if let gitCommonDirectoryPath, gitCommonDirectoryPath.isEmpty == false {
            gitCommonDirectoryPath
        } else {
            repoRoot
        }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
