import BuildrBridgeContracts
import Darwin
import Foundation

/// Offline command effects. There is deliberately no application-launch or wait effect.
struct TrackingCommandExecution {
    var read: (URL) throws -> Data = { try ReportFileExchange.read($0) }
    var publish: (URL, Data) throws -> Void = { try $1.write(to: $0, options: .atomic) }
    var now: () -> Double = { Date().timeIntervalSince1970 }
    var output: (String) -> Void = { print($0) }

    func run(scopePath: String, executionPath: String?,
             acknowledgementPath: String? = nil, rewritePath: String? = nil) throws {
        let result: TrackingResult
        do {
            result = try perform(scopePath: scopePath, executionPath: executionPath,
                                 acknowledgementPath: acknowledgementPath, rewritePath: rewritePath)
        } catch let failure as TrackingFailure {
            result = .init(version: 1, status: failure.status, action: failure.action, records: [])
        } catch let failure as ReportExchangeError {
            let status: TrackingResult.Status = switch failure.failure.code {
            case .busy: .busy
            case .invalidInput: .invalidInput
            default: .failed
            }
            result = .init(version: 1, status: status, action: failure.failure.action, records: [])
        } catch {
            result = .init(version: 1, status: .invalidInput,
                           action: "Check owned v1 files, full commit IDs and scope. "
                               + "Rewrites require explicit pairs, amend/rebase/explicit kind and invocation ID. "
                               + "Deletions and inferred mappings are unsupported.",
                           records: [])
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let json = try String(data: encoder.encode(result), encoding: .utf8) else {
            throw TrackingCommandFailure()
        }
        output(json)
        guard [.queued, .replay, .acknowledged].contains(result.status) else { throw TrackingCommandFailure() }
    }

    private func perform(scopePath: String, executionPath: String?,
                         acknowledgementPath: String?, rewritePath: String?) throws -> TrackingResult {
        let scope = try JSONDecoder().decode(BridgeScope.self, from: read(URL(fileURLWithPath: scopePath)))
        try BridgeValidator.validate(scope)
        let directory = try authorizedDirectory(scope)
        let descriptor = try ReportFileExchange.acquireLock(parent: directory.appending(path: "unused"),
                                                            name: "tracking.lock")
        defer { Darwin.close(descriptor) }
        // Authorization is re-read under the same lock used by the app when changing enablement.
        try authorize(scope, directory: directory)
        let stateURL = directory.appending(path: "records.json")
        var ledger = try load(stateURL, scope: scope)
        let records: [TrackingRecord]
        var rewrites: [TrackingRewriteRecord] = []
        let status: TrackingResult.Status
        if let executionPath {
            let proof = try JSONDecoder().decode(TrackingCommitExecution.self,
                                                 from: read(URL(fileURLWithPath: executionPath)))
            let receipt = try validate(proof, scope: scope)
            if let existing = ledger.entries.first(where: { $0.record.receipt.recordID == receipt.recordID }) {
                guard existing.record.execution == proof else {
                    throw TrackingFailure(.invalidInput, "This event ID identifies different completion evidence.")
                }
                records = [existing.record]
                status = existing.acknowledged ? .acknowledged : .queued
            } else {
                let instant = now()
                guard instant.isFinite, instant >= 0 else { throw BridgeValidationError.invalidTime }
                let record = TrackingRecord(version: 1, scope: scope, receipt: receipt,
                                            execution: proof, recordedAt: instant)
                ledger.entries.append(.init(record: record, acknowledged: false))
                try save(ledger, to: stateURL)
                records = [record]
                status = .queued
            }
        } else if let rewritePath {
            let queued = try queueRewrite(rewritePath, scope: scope, ledger: &ledger, stateURL: stateURL)
            rewrites = queued.records
            status = queued.status
            records = []
        } else if let acknowledgementPath {
            try acknowledge(acknowledgementPath, scope: scope, ledger: &ledger, stateURL: stateURL)
            records = []
            status = .acknowledged
        } else {
            records = ledger.entries.filter { !$0.acknowledged }.map(\.record)
            rewrites = (ledger.rewrites ?? []).filter { !$0.acknowledged }.map(\.record)
            status = .replay
        }
        return .init(version: 1, status: status,
                     action: "Retain receipts. Acknowledge after durable idempotent app ingestion.",
                     records: records, rewrites: rewrites)
    }

    private func queueRewrite(_ path: String, scope: BridgeScope, ledger: inout TrackingLedger,
                              stateURL: URL) throws
        -> (records: [TrackingRewriteRecord], status: TrackingResult.Status) {
        let proof = try JSONDecoder().decode(TrackingRewriteExecution.self, from: read(URL(fileURLWithPath: path)))
        let receipt = try BridgeValidator.validate(proof, scope: scope)
        if let existing = ledger.rewrites?.first(where: { $0.record.receipt.recordID == receipt.recordID }) {
            guard existing.record.execution == proof else {
                throw TrackingFailure(.invalidInput, "This rewrite ID identifies different explicit mappings.")
            }
            return ([existing.record], existing.acknowledged ? .acknowledged : .queued)
        }
        let instant = now()
        guard instant.isFinite, instant >= 0 else { throw BridgeValidationError.invalidTime }
        let record = TrackingRewriteRecord(version: 1, scope: scope, receipt: receipt,
                                           execution: proof, recordedAt: instant)
        ledger.rewrites = (ledger.rewrites ?? []) + [.init(record: record, acknowledged: false)]
        try save(ledger, to: stateURL)
        return ([record], .queued)
    }

    private func acknowledge(_ acknowledgementPath: String, scope: BridgeScope,
                             ledger: inout TrackingLedger, stateURL: URL) throws {
        let acknowledgement = try JSONDecoder().decode(BridgeAcknowledgement.self,
                                                       from: read(URL(fileURLWithPath: acknowledgementPath)))
        let request = BridgeRequest(version: 1, requestID: "ack", scope: scope,
                                    createdAt: 0, deadline: 1, body: .acknowledge(acknowledgement))
        try BridgeValidator.validate(request, expectedScope: scope)
        let identifiers = Set(acknowledgement.recordIDs)
        guard identifiers.isSubset(of: Set(ledger.entries.map(\.record.receipt.recordID)
                + (ledger.rewrites ?? []).map(\.record.receipt.recordID))) else {
            throw TrackingFailure(.invalidInput, "Acknowledge only exact records durably ingested for this scope.")
        }
        let matching = ledger.entries.indices.filter {
            identifiers.contains(ledger.entries[$0].record.receipt.recordID)
        }
        for index in matching {
            ledger.entries[index].acknowledged = true
        }
        if var rewrites = ledger.rewrites {
            for index in rewrites.indices where identifiers.contains(rewrites[index].record.receipt.recordID) {
                rewrites[index].acknowledged = true
            }
            ledger.rewrites = rewrites
        }
        try save(ledger, to: stateURL)
    }

    private func authorizedDirectory(_ scope: BridgeScope) throws -> URL {
        var directory = URL(fileURLWithPath: scope.rootPath)
        guard directory.resolvingSymlinksInPath().path == directory.path else {
            throw TrackingFailure(.invalidInput, "Use the canonical authorized project root without symlinks.")
        }
        for component in [".buildrai", "tracking", "v1"] {
            directory.append(path: component)
            guard FileManager.default.fileExists(atPath: directory.path) else {
                throw TrackingFailure(.missingSetup, "Enable commit tracking for this project in BuildrAI, then retry.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  attributes[.ownerAccountID] as? UInt32 == getuid() else {
                throw TrackingFailure(.invalidInput, "Repair tracking directory ownership or symlinks in BuildrAI.")
            }
        }
        return directory
    }

    private func authorize(_ scope: BridgeScope, directory: URL) throws {
        let url = directory.appending(path: "config.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TrackingFailure(.missingSetup, "Enable commit tracking for this project in BuildrAI, then retry.")
        }
        let configuration = try JSONDecoder().decode(TrackingConfiguration.self, from: read(url))
        guard configuration.version == 1 else {
            throw TrackingFailure(.incompatibleVersion, "Install a compatible protocol v1 BuildrAI/CLI pair.")
        }
        guard configuration.scope == scope else {
            throw TrackingFailure(.invalidInput, "Use the app-authorized canonical repository, project and root.")
        }
        guard configuration.enabled else {
            throw TrackingFailure(.disabled, "Commit tracking is disabled. Enable it for this project in BuildrAI.")
        }
    }

    private func validate(_ proof: TrackingCommitExecution, scope: BridgeScope) throws -> BridgeCommitReceipt {
        try BridgeValidator.validate(proof, scope: scope)
    }

    private func load(_ url: URL, scope: BridgeScope) throws -> TrackingLedger {
        guard FileManager.default.fileExists(atPath: url.path) else { return .init(version: 1, entries: []) }
        let ledger = try JSONDecoder().decode(TrackingLedger.self, from: read(url))
        let identifiers = ledger.entries.map(\.record.receipt.recordID)
            + (ledger.rewrites ?? []).map(\.record.receipt.recordID)
        guard ledger.version == 1, identifiers.count <= 4096,
              Set(identifiers).count == identifiers.count else {
            throw TrackingFailure(.failed, "Repair the tracking ledger in BuildrAI; records were not overwritten.")
        }
        for entry in ledger.entries {
            guard entry.record.version == 1, entry.record.scope == scope,
                  entry.record.recordedAt.isFinite, entry.record.recordedAt >= 0,
                  try validate(entry.record.execution, scope: scope) == entry.record.receipt else {
                throw TrackingFailure(.failed, "Repair invalid retained tracking records in BuildrAI.")
            }
        }
        for entry in ledger.rewrites ?? [] {
            do {
                guard entry.record.version == 1, entry.record.scope == scope,
                      entry.record.recordedAt.isFinite, entry.record.recordedAt >= 0,
                      try BridgeValidator.validate(entry.record.execution, scope: scope) == entry.record.receipt else {
                    throw BridgeValidationError.invalidPayload
                }
            } catch {
                throw TrackingFailure(.failed,
                                      "Repair invalid retained rewrite records in BuildrAI; state was not changed.")
            }
        }
        return ledger
    }

    private func save(_ ledger: TrackingLedger, to url: URL) throws {
        let data = try JSONEncoder().encode(ledger)
        guard ledger.entries.count + (ledger.rewrites?.count ?? 0) <= 4096, data.count <= 4 * 1024 * 1024 else {
            throw TrackingFailure(.failed, "Tracking storage is full. Retain the ledger and upgrade storage capacity.")
        }
        do {
            try publish(url, data)
        } catch {
            throw TrackingFailure(.failed, "Write failed. Repair disk space/permissions; retry the same event ID.")
        }
    }
}

private struct TrackingLedger: Codable {
    struct Entry: Codable {
        let record: TrackingRecord
        var acknowledged: Bool
    }

    struct RewriteEntry: Codable {
        let record: TrackingRewriteRecord
        var acknowledged: Bool
    }

    let version: Int
    var entries: [Entry]
    var rewrites: [RewriteEntry]?
}

private struct TrackingFailure: Error {
    let status: TrackingResult.Status
    let action: String
    init(_ status: TrackingResult.Status, _ action: String) {
        self.status = status
        self.action = action
    }
}

struct TrackingCommandFailure: Error {}
