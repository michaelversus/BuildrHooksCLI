import Foundation

public struct RepositoryRootLocator: Sendable {
    public init() {}

    public func repositoryRoot(startingAt currentWorkingDirectory: String) -> URL {
        var currentURL = URL(fileURLWithPath: currentWorkingDirectory, isDirectory: true).standardizedFileURL
        let fileManager = FileManager.default

        while true {
            let gitMarkerURL = currentURL.appending(path: ".git")
            if fileManager.fileExists(atPath: gitMarkerURL.path) {
                return currentURL
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                return URL(fileURLWithPath: currentWorkingDirectory, isDirectory: true).standardizedFileURL
            }
            currentURL = parentURL
        }
    }
}
