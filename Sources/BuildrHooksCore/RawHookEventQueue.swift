import Foundation

public struct RawHookEventQueuePaths: Equatable, Sendable {
    public let baseDirectory: URL
    public let rawHooksDirectory: URL
    public let archiveDirectory: URL
    public let processedArchiveDirectory: URL
    public let bridgeCLIVersionMarker: URL

    public init(repositoryRoot: URL) {
        baseDirectory = repositoryRoot
            .appending(path: ".buildrai", directoryHint: .isDirectory)
            .standardizedFileURL
        rawHooksDirectory = baseDirectory
            .appending(path: "inbox/raw-hooks", directoryHint: .isDirectory)
        archiveDirectory = baseDirectory
            .appending(path: "archive", directoryHint: .isDirectory)
        processedArchiveDirectory = archiveDirectory
            .appending(path: "raw-hooks-processed", directoryHint: .isDirectory)
        bridgeCLIVersionMarker = baseDirectory.appending(path: "bridge-cli-version.json")
    }
}

public struct RawHookEventQueue {
    public var fileManager: FileManager
    public var now: @Sendable () -> Date
    public var makeID: @Sendable () -> UUID
    public var bridgeCLIVersion: String?

    public init(
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init,
        makeID: @escaping @Sendable () -> UUID = UUID.init,
        bridgeCLIVersion: String? = nil
    ) {
        self.fileManager = fileManager
        self.now = now
        self.makeID = makeID
        self.bridgeCLIVersion = bridgeCLIVersion
    }

    public func paths(for repositoryRoot: URL) -> RawHookEventQueuePaths {
        RawHookEventQueuePaths(repositoryRoot: repositoryRoot)
    }

    @discardableResult
    public func enqueue(_ event: some Encodable, in repositoryRoot: URL) throws -> URL {
        let paths = paths(for: repositoryRoot)
        try fileManager.createDirectory(
            at: paths.rawHooksDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )
        try fileManager.createDirectory(
            at: paths.processedArchiveDirectory,
            withIntermediateDirectories: true,
            attributes: nil
        )

        let fileURL = paths.rawHooksDirectory.appending(path: makeFilename())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        try data.write(to: fileURL, options: .atomic)

        if let bridgeCLIVersion {
            // Marker failure must not turn a successfully queued hook into a failed enqueue.
            try? writeBridgeCLIVersionMarker(bridgeCLIVersion, at: paths.bridgeCLIVersionMarker)
        }
        return fileURL
    }

    private func writeBridgeCLIVersionMarker(_ version: String, at markerURL: URL) throws {
        let marker = BridgeCLIVersionMarker(version: version)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(marker)

        if let existingData = try? Data(contentsOf: markerURL),
           let existingMarker = try? JSONDecoder().decode(BridgeCLIVersionMarker.self, from: existingData),
           existingMarker.version == version {
            return
        }
        try data.write(to: markerURL, options: .atomic)
    }

    private func makeFilename() -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmssSSS'Z'"
        return "\(formatter.string(from: now()))-\(makeID().uuidString.lowercased()).json"
    }
}

/// The BuildrHooksCLI version that most recently handled a hook in this repository.
/// It does not describe every installed executable and may lag a Homebrew upgrade
/// until another hook runs successfully.
private struct BridgeCLIVersionMarker: Codable {
    let version: String
}
