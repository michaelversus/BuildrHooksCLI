import Foundation

struct UsageFetchResult {
    let outcome: UsageOutcome
    let retryAt: Int64?
    let snapshot: UsageSnapshot?
    var identity: String?
}

struct UsageCompletion {
    let provider: UsageProvider
    let fetched: UsageFetchResult
    let outcome: UsageOutcome
    let retryAt: Int64?
}

struct UsagePublicationError: Error {
    let attempted: Bool
}

extension UsageRuntime {
    func statusCode(for outcome: UsageOutcome) -> UsageStatusCode {
        switch outcome {
        case .refreshed: .ready
        case .authenticationRequired: .authenticationRequired
        case .throttled: .throttled
        case .usageUnavailable: .usageUnavailable
        default: .temporaryFailure
        }
    }

    func finish(
        _ completion: UsageCompletion, state: inout UsageProviderState, durable: inout UsageDurableState
    ) -> UsageRefreshResult {
        let provider = completion.provider
        let fetched = completion.fetched
        let outcome = completion.outcome
        let retryAt = completion.retryAt
        state.retryNotBefore = retryAt
        if fetched.identity == nil, fetched.snapshot == nil {
            recovery.unverify(provider)
        }
        reconcileIdentity(fetched.identity, provider: provider, state: &state)
        let fresh = fetched.snapshot.flatMap { snapshot -> UsageSnapshot? in
            guard let collectedAt = snapshot.collectedAt else { return nil }
            return UsageSnapshot(provider: provider, revision: state.revision + 1,
                                 collectedAt: collectedAt, windows: snapshot.windows)
        }
        if let fresh {
            if fetched.identity == nil {
                state.accountFingerprint = nil
            }
            state.snapshot = fresh
            state.revision += 1
        }
        state.revision += 1
        let code = statusCode(for: outcome)
        state.status = status(code, provider: provider, state: state, retryAt: retryAt)
        durable.providers[provider.rawValue] = state
        do { try store.save(durable) } catch { return result(provider, .persistenceFailure, fresh: fresh != nil) }
        guard !isCancelled() else { return result(provider, .cancelled) }
        if fresh != nil {
            recovery.verify(provider)
        }
        do {
            let attempted = try publish(snapshot: fresh, status: state.status)
            return result(provider, outcome, retryAt: retryAt, fresh: fresh != nil, attempted: attempted)
        } catch let attempted as UsagePublicationError {
            return result(provider, .publicationFailure, fresh: fresh != nil, attempted: attempted.attempted)
        } catch { return result(provider, .publicationFailure, fresh: fresh != nil) }
    }

    func retryAt(
        for outcome: UsageOutcome, fetchedRetryAt: Int64?, state: inout UsageProviderState
    ) -> Int64? {
        if outcome == .temporaryFailure || outcome == .timeout || outcome == .executableUnavailable {
            let failures = min(20, (state.temporaryFailureCount ?? 0) + 1)
            state.temporaryFailureCount = failures
            let base = min(300.0, 30 * pow(2, Double(failures - 1)))
            let random = jitter()
            let fraction = random.isFinite ? min(1, max(0, random)) : 0
            return milliseconds() + Int64(min(300, base * (1 + fraction * 0.2)) * 1000)
        }
        if outcome == .throttled {
            return max(fetchedRetryAt ?? 0, milliseconds() + 30000)
        }
        state.temporaryFailureCount = 0
        return fetchedRetryAt
    }
}
