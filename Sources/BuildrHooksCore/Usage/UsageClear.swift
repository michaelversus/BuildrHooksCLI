import Foundation

public extension UsageRuntime {
    /// Call only under exclusive ownership, or from the synchronous private control dispatcher.
    /// Publication reports an attempt; distributed notifications cannot confirm receiver clearing.
    func clear(provider: UsageProvider = .codex) -> UsageRefreshResult {
        guard provider == .codex || additionalFetchers[provider] != nil else {
            return result(provider, .unsupportedProvider)
        }
        guard !isCancelled() else { return result(provider, .cancelled) }
        let cleared: UsageCollectionStatus
        var expectedInvalidation: UInt64?
        do {
            var durable = try store.load()
            var state = durable.providers[provider.rawValue] ?? .init()
            guard state.revision < UInt64.max - 1 else { return result(provider, .persistenceFailure) }
            state.revision += 1
            state.latestInvalidationRevision = state.revision
            state.snapshot = nil
            state.revision += 1
            // Failures and provider retry restrictions survive clearing values.
            let code = state.status?.status == .ready ? UsageStatusCode.pending : (state.status?.status ?? .pending)
            cleared = status(code, provider: provider, state: state, retryAt: state.status?.retryAt)
            state.status = cleared
            durable.providers[provider.rawValue] = state
            expectedInvalidation = state.latestInvalidationRevision
            try store.save(durable)
        } catch {
            return clearPersistenceFailure(provider: provider, expectedInvalidation: expectedInvalidation)
        }
        recovery.unverify(provider)
        do {
            let attempted = try publish(snapshot: nil, status: cleared)
            return UsageRefreshResult(provider: provider, outcome: .cleared, retryAt: nil,
                                      freshSnapshot: false, publicationAttempted: attempted, localCleared: true)
        } catch let error as UsagePublicationError {
            return UsageRefreshResult(provider: provider, outcome: .publicationFailure, retryAt: nil,
                                      freshSnapshot: false, publicationAttempted: error.attempted, localCleared: true)
        } catch {
            return UsageRefreshResult(provider: provider, outcome: .publicationFailure, retryAt: nil,
                                      freshSnapshot: false, publicationAttempted: false, localCleared: true)
        }
    }

    private func clearPersistenceFailure(
        provider: UsageProvider, expectedInvalidation: UInt64?
    ) -> UsageRefreshResult {
        // Rename can succeed before the durability acknowledgement fails. Read-back
        // confirms local visibility only; never publish without a successful save.
        let state = try? store.load().providers[provider.rawValue]
        let localCleared = expectedInvalidation.map {
            state?.latestInvalidationRevision == $0 && state?.snapshot == nil
        } ?? false
        recovery.unverify(provider)
        return UsageRefreshResult(provider: provider, outcome: .persistenceFailure, retryAt: nil,
                                  freshSnapshot: false, publicationAttempted: false, localCleared: localCleared)
    }
}
