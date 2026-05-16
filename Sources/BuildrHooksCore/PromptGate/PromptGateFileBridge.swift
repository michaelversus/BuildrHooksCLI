import Darwin
import Foundation

public struct PromptGateFileBridge {
    public struct Paths: Equatable, Sendable {
        public let directory: URL
        public let lock: URL
        public let request: URL
        public let response: URL
        public let staleDirectory: URL
    }

    public var fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func paths(for repositoryRoot: URL) -> Paths {
        let directory = repositoryRoot
            .appending(path: ".buildrai/hooks/prompt-eval", directoryHint: .isDirectory)
            .standardizedFileURL
        return Paths(
            directory: directory,
            lock: directory.appending(path: "inflight.lock"),
            request: directory.appending(path: "request.json"),
            response: directory.appending(path: "response.json"),
            staleDirectory: directory.appending(path: "stale", directoryHint: .isDirectory)
        )
    }

    public func acquireLock(requestID: String, repositoryRoot: URL, createdAt: Date) throws -> Paths {
        let paths = paths(for: repositoryRoot)
        try fileManager.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: paths.staleDirectory, withIntermediateDirectories: true)
        try rejectSymlinkIfPresent(paths.lock)

        let descriptor = open(paths.lock.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            if errno == EEXIST {
                throw PromptGateExit(
                    code: .busy,
                    message: "Prompt Gate is already evaluating another prompt for this repository. Try again shortly."
                )
            }
            throw PromptGateExit(
                code: .protocolError,
                message: "Prompt Gate could not create inflight lock: \(String(cString: strerror(errno)))"
            )
        }

        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let payload = #"{"request_id":"\#(requestID)","created_at":"\#(formatter.string(from: createdAt))"}"#
        try handle.write(contentsOf: Data(payload.utf8))
        try handle.close()
        return paths
    }

    public func writeRequest(_ request: PromptGateRequest, paths: Paths) throws {
        try rejectSymlinkIfPresent(paths.request)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(request)
        let temporaryURL = paths.directory.appending(path: ".request-\(request.requestID).tmp")
        try data.write(to: temporaryURL, options: .atomic)
        if fileManager.fileExists(atPath: paths.request.path) {
            try fileManager.removeItem(at: paths.request)
        }
        try fileManager.moveItem(at: temporaryURL, to: paths.request)
    }

    public func readResponse(paths: Paths) throws -> PromptGateResponse? {
        guard fileManager.fileExists(atPath: paths.response.path) else {
            return nil
        }

        try rejectSymlinkIfPresent(paths.response)
        let data = try Data(contentsOf: paths.response)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PromptGateResponse.self, from: data)
    }

    public func cleanOwnedFiles(paths: Paths, requestID: String) {
        if lockIsOwnedByRequest(paths.lock, requestID: requestID) {
            try? fileManager.removeItem(at: paths.lock)
        }

        for url in [paths.request, paths.response] where fileManager.fileExists(atPath: url.path) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func rejectSymlinkIfPresent(_ url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
            throw PromptGateExit(
                code: .protocolError,
                message: "Prompt Gate refused to use symlinked file at \(url.path)."
            )
        }
    }

    private func lockIsOwnedByRequest(_ url: URL, requestID: String) -> Bool {
        guard let data = try? Data(contentsOf: url),
              let string = String(data: data, encoding: .utf8)
        else {
            return false
        }
        return string.contains(#""request_id":"\#(requestID)""#)
    }
}
