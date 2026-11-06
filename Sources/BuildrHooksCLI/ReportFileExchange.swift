import BuildrBridgeContracts
import Darwin
import Foundation

struct ReportFileSystem {
    var readInput: (URL) throws -> Data = { try ReportFileExchange.read($0) }
    var cancel: (BridgeRequest) throws -> BridgeResponse = { try ReportWorkflowStore.cancel($0) }
    var begin: (BridgeRequest) throws -> ReportHandoff = { try ReportFileExchange(request: $0) }
}

protocol ReportHandoff {
    func readResponse() throws -> BridgeResponse?
    func retain(_ packet: BridgeEvidencePacket) throws
    func complete() throws
    func close()
    func checkCancellation() throws
    func terminate(_ code: BridgeFailure.Code) throws
}

final class ReportFileExchange: ReportHandoff {
    private let directory: URL
    private let request: BridgeRequest
    private let store: ReportWorkflowStore
    private let descriptor: Int32
    private var closed = false
    private var ownsDirectory = false
    private var retained = false
    private var workflowDirectory: URL?

    init(request: BridgeRequest) throws {
        self.request = request
        let manager = FileManager.default
        let parent = try Self.requestParent(rootPath: request.scope.rootPath)
        store = ReportWorkflowStore(parent: parent)
        descriptor = try Self.acquireLock(parent: parent)
        guard !request.requestID.isEmpty, request.requestID.rangeOfCharacter(
            from: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-").inverted
        ) == nil else {
            Darwin.close(descriptor)
            throw ReportExchangeError(.invalidInput, "Use a filesystem-safe reporting request ID.")
        }
        directory = parent.appending(path: request.requestID)
        do {
            try store.recover(scope: request.scope, now: request.createdAt)
            try store.requireFresh(request)
            workflowDirectory = try Self.preparedWorkflow(for: request, parent: parent)
            guard !manager.fileExists(atPath: directory.path) else {
                throw ReportExchangeError(.busy, "This request ID already exists. Retry with a fresh ID.")
            }
            try manager.createDirectory(at: directory, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
        } catch {
            closed = true
            Darwin.close(descriptor)
            throw error
        }
        ownsDirectory = true
        do {
            let data = try JSONEncoder().encode(request)
            guard data.count <= 4 * 1024 * 1024 else {
                throw ReportExchangeError(.invalidInput, "Reduce this request below the 4 MiB transport budget.")
            }
            try data.write(to: directory.appending(path: "request.json"), options: .atomic)
        } catch {
            closed = true
            try? manager.removeItem(at: directory)
            Darwin.close(descriptor)
            throw error
        }
    }

    /// A fresh transport request refers to an existing immutable preparation.
    /// Never trust a caller-supplied packet or the app's replaceable response slot.
    static func preparedWorkflow(for request: BridgeRequest, parent: URL) throws -> URL? {
        guard case let .finalize(content) = request.body else { return nil }
        let identifier = content.snapshot.requestID
        guard identifier != request.requestID, !identifier.isEmpty,
              identifier.rangeOfCharacter(from: CharacterSet(
                  charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
              ).inverted) == nil else {
            throw ReportExchangeError(.invalidInput,
                                      "Use the prepared workflow ID and a fresh finalization request ID.")
        }
        let directory = parent.appending(path: identifier)
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.ownerAccountID] as? UInt32 == getuid() else {
            throw ReportExchangeError(.invalidInput, "Use an owned prepared workflow without symlinks.")
        }
        let packet = try JSONDecoder().decode(
            BridgeEvidencePacket.self, from: read(directory.appending(path: "packet.json"))
        )
        let preparation = try JSONDecoder().decode(
            BridgeRequest.self, from: read(directory.appending(path: "request.json"))
        )
        try BridgeValidator.validate(preparation, expectedScope: request.scope)
        try BridgeValidator.validate(
            BridgeResponse(version: 1, requestID: preparation.requestID, scope: preparation.scope,
                           body: .prepared(packet)), for: preparation
        )
        try BridgeValidator.validate(request, expectedScope: request.scope, preparedPacket: packet)
        return directory
    }

    func checkCancellation() throws {
        let workflowCancelled = try workflowDirectory.map {
            try store.isCancelled(scope: request.scope, requestID: $0.lastPathComponent)
        } ?? false
        if try store.isCancelled(request) || workflowCancelled {
            throw ReportExchangeError(.cancelled, "Reporting workflow cancelled.")
        }
    }

    func terminate(_ code: BridgeFailure.Code) throws {
        try store.withMutation {
            retained = false
            try store.end(request, code: code)
            if let workflowDirectory {
                let preparation = try store.load(workflowDirectory.lastPathComponent, scope: request.scope)
                try store.end(preparation, code: code)
            }
            finishWorkflow()
        }
    }

    func complete() throws {
        try store.withMutation {
            try checkCancellation()
            if let workflowDirectory {
                let preparation = try store.load(workflowDirectory.lastPathComponent, scope: request.scope)
                try store.complete(preparation)
            }
            try store.complete(request)
            finishWorkflow()
        }
    }

    private func finishWorkflow() {
        if let workflowDirectory {
            try? FileManager.default.removeItem(at: workflowDirectory)
        }
    }

    static func requestParent(rootPath: String) throws -> URL {
        let manager = FileManager.default
        var parent = URL(fileURLWithPath: rootPath)
        guard parent.resolvingSymlinksInPath().path == parent.path else {
            throw ReportExchangeError(.invalidInput, "Use the canonical authorized project root.")
        }
        for component in [".buildrai", "reporting", "v1", "requests"] {
            parent.append(path: component)
            if !manager.fileExists(atPath: parent.path) {
                try manager.createDirectory(at: parent, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            }
            let attributes = try manager.attributesOfItem(atPath: parent.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  attributes[.ownerAccountID] as? UInt32 == getuid() else {
                throw ReportExchangeError(.invalidInput, "Use owned reporting directories without symlinks.")
            }
        }
        return parent
    }

    static func acquireLock(parent: URL, name: String = "inflight.lock") throws -> Int32 {
        let lock = parent.deletingLastPathComponent().appending(path: name)
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else {
            throw ReportExchangeError(.failed, "Repair reporting lock permissions and retry.")
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
              info.st_mode & S_IFMT == S_IFREG else {
            Darwin.close(descriptor)
            throw ReportExchangeError(.failed, "Repair reporting lock ownership and retry.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ReportExchangeError(.busy, "Another report owns this repository. Wait for it to finish.")
        }
        return descriptor
    }

    static func read(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            throw ReportExchangeError(.invalidInput, "Provide an accessible regular JSON file, without symlinks.")
        }
        defer { Darwin.close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_size <= 4 * 1024 * 1024 else {
            throw ReportExchangeError(.invalidInput, "Use an owned regular JSON file under 4 MiB.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
    }

    func readResponse() throws -> BridgeResponse? {
        let url = directory.appending(path: "response.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(BridgeResponse.self, from: Self.read(url))
    }

    /// A successful preparation ends collection, but its identified workflow continues.
    /// Persist the validated value separately from the app's replaceable response slot.
    func retain(_ packet: BridgeEvidencePacket) throws {
        let data = try JSONEncoder().encode(packet)
        guard data.count <= 4 * 1024 * 1024 else {
            throw ReportExchangeError(.invalidInput, "Reduce evidence below the 4 MiB transport budget.")
        }
        try data.write(to: directory.appending(path: "packet.json"), options: .atomic)
        retained = true
    }

    func close() {
        guard !closed else { return }
        closed = true
        if ownsDirectory, !retained {
            try? FileManager.default.removeItem(at: directory)
        }
        // Keep the inode so another flock owner cannot bypass it.
        Darwin.close(descriptor)
    }

    deinit { close() }
}
