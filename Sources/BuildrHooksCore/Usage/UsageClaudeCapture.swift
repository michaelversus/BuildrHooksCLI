import Foundation

public extension UsageRuntime {
    /// Sample before reading/normalizing a callback. Clear fences out all older pending work.
    func claudeCaptureGeneration() throws -> UInt64 {
        try store.load().providers[UsageProvider.claude.rawValue]?.latestClearRevision ?? 0
    }

    /// The caller holds the existing exclusive ownership lock, as for collection and clear.
    /// Nil windows mean malformed capture; an empty array is a valid report with no quota.
    func acceptClaude(windows: [UsageWindow]?, generation: UInt64) -> UsageRefreshResult {
        guard !isCancelled() else { return result(.claude, .cancelled) }
        guard let cliVersion else { return result(.claude, .persistenceFailure) }
        var durable: UsageDurableState
        do { durable = try store.load() } catch { return result(.claude, .persistenceFailure) }
        var state = durable.providers[UsageProvider.claude.rawValue] ?? .init()
        guard generation == state.latestClearRevision ?? 0 else { return result(.claude, .invalidated) }
        guard state.revision < UInt64.max - 2 else { return result(.claude, .persistenceFailure) }
        let receivedAt = milliseconds()
        if let windows {
            state.revision += 1
            if windows.isEmpty {
                state.latestInvalidationRevision = state.revision
                state.snapshot = nil
            } else {
                let snapshot = UsageSnapshot(revision: state.revision, receivedAt: receivedAt, windows: windows,
                                             cliVersion: cliVersion)
                guard (try? UsageWire().encode(snapshot, now: now())) != nil else {
                    return result(.claude, .temporaryFailure)
                }
                state.snapshot = snapshot
            }
        }
        state.revision += 1
        let code: UsageStatusCode = windows == nil
            ? .temporaryFailure : (windows?.isEmpty == true ? .usageUnavailable : .ready)
        state.status = UsageCollectionStatus(
            revision: state.revision, observedAt: milliseconds(), status: code,
            latestInvalidationRevision: state.latestInvalidationRevision,
            retainedSnapshotRevision: state.snapshot?.revision,
            receivedAt: windows == nil ? state.snapshot?.receivedAt : receivedAt, cliVersion: cliVersion
        )
        durable.providers[UsageProvider.claude.rawValue] = state
        do { try store.save(durable) } catch { return result(.claude, .persistenceFailure) }
        return publishClaudeCapture(state, accepted: windows != nil)
    }
}

extension UsageRuntime {
    private func publishClaudeCapture(_ state: UsageProviderState, accepted: Bool) -> UsageRefreshResult {
        let outcome: UsageOutcome = accepted
            ? (state.snapshot == nil ? .usageUnavailable : .refreshed) : .temporaryFailure
        do {
            let attempted = try publish(snapshot: accepted ? state.snapshot : nil, status: state.status)
            return result(.claude, outcome, fresh: accepted && state.snapshot != nil, attempted: attempted)
        } catch let error as UsagePublicationError {
            return result(.claude, .publicationFailure, attempted: error.attempted)
        } catch { return result(.claude, .publicationFailure) }
    }
}

public extension UsageCoordination {
    /// The input closure permits a clear concurrent with stdin/normalization to retire that callback.
    /// Only bounded normalized quota crosses the private socket; no original callback is sent.
    func captureClaude(runtime: UsageRuntime, timeout: TimeInterval = 2,
                       input: () throws -> Data) -> UsageRefreshResult {
        let generation: UInt64
        do { generation = try runtime.claudeCaptureGeneration() } catch {
            return runtime.result(.claude, .persistenceFailure)
        }
        let windows = try? ClaudeUsageParser().windows(from: input())
        return refresh(runtime: runtime, timeout: timeout, cancelled: runtime.isCancelled,
                       request: UsagePrivateRequest(windows: windows, generation: generation))
    }
}

extension UsageWatchTrigger {
    var requestsCollection: Bool {
        switch self {
        case .recoveryRequested, .claudeRecoveryRequested: false
        default: true
        }
    }
}
