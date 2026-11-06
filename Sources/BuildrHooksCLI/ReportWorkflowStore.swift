import BuildrBridgeContracts
import Darwin
import Foundation

/// Repository-local lifecycle metadata contains identities and deadlines, never evidence/prose.
/// Terminal receipts fence reused IDs and let the app discard work after the CLI exits.
struct ReportWorkflowStore {
    let parent: URL

    private func directory(_ identifier: String) throws -> URL {
        guard !identifier.isEmpty, identifier.rangeOfCharacter(from: CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-"
        ).inverted) == nil else {
            throw ReportExchangeError(.invalidInput, "Use a filesystem-safe reporting request ID.")
        }
        return parent.appending(path: identifier)
    }

    private func ownedDirectory(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              attributes[.ownerAccountID] as? UInt32 == getuid() else {
            throw ReportExchangeError(.invalidInput, "Use an owned reporting directory without symlinks.")
        }
    }

    func load(_ identifier: String, scope: BridgeScope) throws -> BridgeRequest {
        let directory = try directory(identifier)
        try ownedDirectory(directory)
        let request = try JSONDecoder().decode(BridgeRequest.self, from:
            ReportFileExchange.read(directory.appending(path: "request.json")))
        guard request.requestID == identifier, request.scope == scope, request.version == 1,
              request.createdAt.isFinite, request.deadline.isFinite,
              request.createdAt >= 0, request.deadline > request.createdAt else {
            throw ReportExchangeError(.invalidInput, "Use the matching authorized reporting workflow.")
        }
        return request
    }

    private func terminalURL(_ identifier: String) throws -> URL {
        _ = try directory(identifier)
        let ended = parent.deletingLastPathComponent().appending(path: "ended")
        if !FileManager.default.fileExists(atPath: ended.path) {
            try FileManager.default.createDirectory(at: ended, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try ownedDirectory(ended)
        return ended.appending(path: identifier + ".json")
    }

    func requireFresh(_ request: BridgeRequest) throws {
        if try FileManager.default.fileExists(atPath: terminalURL(request.requestID).path) {
            throw ReportExchangeError(.invalidInput, "This reporting request ended. Retry with a fresh request ID.")
        }
    }

    func withMutation<T>(_ body: () throws -> T) throws -> T {
        let descriptor = try ReportFileExchange.acquireLock(parent: parent, name: "lifecycle.lock")
        defer { Darwin.close(descriptor) }
        return try body()
    }

    func complete(_ request: BridgeRequest) throws {
        try writeTerminal(request, code: .completed)
    }

    func end(_ request: BridgeRequest, code: BridgeFailure.Code) throws {
        guard try terminal(request) == nil else { return }
        try writeTerminal(request, code: code == .cancelled ? .cancelled : .timeout)
    }

    private func writeTerminal(_ request: BridgeRequest, code: BridgeWorkflowTermination.Disposition) throws {
        let receipt = BridgeWorkflowTermination(requestID: request.requestID, scope: request.scope,
                                                createdAt: request.createdAt, deadline: request.deadline, code: code)
        try JSONEncoder().encode(receipt).write(to: terminalURL(request.requestID), options: .atomic)
    }

    func isCancelled(_ request: BridgeRequest) throws -> Bool {
        guard let receipt = try terminal(request) else { return false }
        return [.cancelled, .timeout].contains(receipt.code)
    }

    private func terminal(_ request: BridgeRequest) throws -> BridgeWorkflowTermination? {
        let url = try terminalURL(request.requestID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let receipt = try JSONDecoder().decode(BridgeWorkflowTermination.self, from: ReportFileExchange.read(url))
        try BridgeValidator.validate(receipt, for: request)
        return receipt
    }

    func isCancelled(scope: BridgeScope, requestID: String) throws -> Bool {
        try isCancelled(load(requestID, scope: scope))
    }

    /// Called only with the repository collection lock. Unknown/foreign entries survive.
    /// Prepared evidence has a 24-hour lease distinct from the collection deadline.
    func recover(scope: BridgeScope, now: Double) throws {
        try withMutation { try recoverLocked(scope: scope, now: now) }
    }

    private func recoverLocked(scope: BridgeScope, now: Double) throws {
        let manager = FileManager.default
        for directory in try manager.contentsOfDirectory(at: parent, includingPropertiesForKeys: nil) {
            guard let request = try? load(directory.lastPathComponent, scope: scope) else { continue }
            let prepared = manager.fileExists(atPath: directory.appending(path: "packet.json").path)
            let expiry = prepared ? request.createdAt + 86400 : request.deadline
            let receipt = try terminal(request)
            guard now >= expiry || receipt != nil else { continue }
            if receipt == nil {
                try end(request, code: .timeout)
            }
            if case .finalize = request.body,
               let workflow = try? ReportFileExchange.preparedWorkflow(for: request, parent: parent),
               let preparation = try? load(workflow.lastPathComponent, scope: scope) {
                try end(preparation, code: .timeout)
                try manager.removeItem(at: workflow)
            }
            try manager.removeItem(at: directory)
        }
    }

    static func cancel(_ request: BridgeRequest) throws -> BridgeResponse {
        guard case let .cancel(cancellation) = request.body else { throw ReportCommandFailure() }
        let parent = try ReportFileExchange.requestParent(rootPath: request.scope.rootPath)
        let store = ReportWorkflowStore(parent: parent)
        try store.withMutation {
            let target = try store.load(cancellation.targetRequestID, scope: request.scope)
            try store.requireFresh(target)
            try store.end(target, code: .cancelled)
        }
        // Publish without the collection lock so an active collector can observe cancellation.
        // The receipt is scoped to the exact original identity/deadline and survives handoff cleanup.
        if let descriptor = try? ReportFileExchange.acquireLock(parent: parent) {
            defer { Darwin.close(descriptor) }
            try store.recover(scope: request.scope, now: request.createdAt)
        }
        return BridgeResponse(version: 1, requestID: request.requestID, scope: request.scope,
                              body: .cancelled(cancellation))
    }
}
