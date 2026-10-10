import Foundation

public enum UsageFetchError: Error, Sendable {
    case authenticationRequired, temporaryFailure, timeout, unavailable
    case throttled(retryAt: Int64?)
    case executableUnavailable
}

public protocol UsageFetching: Sendable {
    /// Implementations must honor this total fetch deadline, including initialization and authentication reads.
    func fetch(timeout: TimeInterval) throws -> Data
}

public protocol UsageNotifying: Sendable {
    func post(name: String, payload: String) throws
}

public struct DistributedUsageNotifier: UsageNotifying {
    public init() {}
    public func post(name: String, payload: String) throws {
        DistributedNotificationCenter.default().postNotificationName(
            Notification.Name(name), object: nil, userInfo: ["payload": payload], deliverImmediately: true
        )
    }
}

public enum UsageOutcome: String, Codable, Sendable {
    case refreshed
    case authenticationRequired = "authentication_required"
    case temporaryFailure = "temporary_failure"
    case throttled, timeout
    case usageUnavailable = "usage_unavailable"
    case persistenceFailure = "persistence_failure"
    case publicationFailure = "publication_failure"
    case executableUnavailable = "executable_unavailable"
    public var exitCode: Int32 {
        switch self {
        case .refreshed: 0
        case .authenticationRequired: 10
        case .temporaryFailure: 11
        case .throttled: 12
        case .timeout: 13
        case .usageUnavailable: 14
        case .persistenceFailure: 15
        case .publicationFailure: 16
        case .executableUnavailable: 17
        }
    }
}

public struct UsageRefreshResult: Codable, Sendable {
    public let provider: UsageProvider
    public let outcome: UsageOutcome
    public let retryAt: Int64?
    public let freshSnapshot: Bool
    public let publicationAttempted: Bool
}

private struct UsageFetchResult {
    let outcome: UsageOutcome
    let retryAt: Int64?
    let snapshot: UsageSnapshot?
}

/// Primary command-to-provider-to-publication seam. It never delivers retained observations.
public struct UsageRuntime: Sendable {
    public static let snapshotNotification = "ai.buildrai.account-usage-updated"
    public static let statusNotification = "ai.buildrai.account-usage-status-updated"
    public var fetcher: any UsageFetching
    public var store: any UsageStateStoring
    public var notifier: any UsageNotifying
    public var now: @Sendable () -> Date
    public var parse: @Sendable (Data) throws -> [UsageWindow]
    public var output: @Sendable (String) -> Void
    public init(
        fetcher: any UsageFetching, store: any UsageStateStoring = UsageFileStateStore(),
        notifier: any UsageNotifying = DistributedUsageNotifier(),
        now: @escaping @Sendable () -> Date = Date.init,
        parse: @escaping @Sendable (Data) throws -> [UsageWindow] = { try CodexUsageParser().windows(from: $0) },
        output: @escaping @Sendable (String) -> Void = { print($0) }
    ) {
        self.fetcher = fetcher
        self.store = store
        self.notifier = notifier
        self.now = now
        self.parse = parse
        self.output = output
    }

    @discardableResult
    public func refresh(provider: UsageProvider = .codex, json: Bool = false) -> UsageRefreshResult {
        let result = collect(provider: provider)
        if json, let data = try? JSONEncoder().encode(result), let json = String(data: data, encoding: .utf8) {
            output(json)
        } else {
            let guidance = result.outcome == .executableUnavailable
                ? " Install Codex or provide an executable with --codex-path." : ""
            output("Codex usage: \(result.outcome.rawValue). Publication attempted: \(result.publicationAttempted)."
                + " Receipt is not acknowledged." + guidance)
        }
        return result
    }

    private func collect(provider: UsageProvider) -> UsageRefreshResult {
        var durable: UsageDurableState
        do { durable = try store.load() } catch { return result(provider, .persistenceFailure) }
        var state = durable.providers[provider.rawValue] ?? .init()
        guard state.revision < UInt64.max - 3 else { return result(provider, .persistenceFailure) }
        state.revision += 1
        state.status = status(.pending, provider: provider, state: state)
        durable.providers[provider.rawValue] = state
        do { try store.save(durable) } catch { return result(provider, .persistenceFailure) }
        publishPendingStatus(state.status)
        let fetched = fetch(provider: provider, revision: state.revision + 1)
        let outcome = fetched.outcome
        let retryAt = fetched.retryAt
        let fresh = fetched.snapshot
        if let fresh {
            state.snapshot = fresh
            state.revision += 1
        }
        state.revision += 1
        let code = statusCode(for: outcome)
        state.status = status(code, provider: provider, state: state, retryAt: retryAt)
        durable.providers[provider.rawValue] = state
        do { try store.save(durable) } catch { return result(provider, .persistenceFailure, fresh: fresh != nil) }
        do {
            let attempted = try publish(snapshot: fresh, status: state.status)
            return result(provider, outcome, retryAt: retryAt, fresh: fresh != nil, attempted: attempted)
        } catch let attempted as UsagePublicationError {
            return result(provider, .publicationFailure, fresh: fresh != nil, attempted: attempted.attempted)
        } catch { return result(provider, .publicationFailure, fresh: fresh != nil) }
    }

    private func publishPendingStatus(_ status: UsageCollectionStatus?) {
        guard let status, let payload = try? UsageWire().encode(status, now: now()) else { return }
        try? notifier.post(name: Self.statusNotification, payload: payload)
    }

    private func fetch(provider: UsageProvider, revision: UInt64) -> UsageFetchResult {
        do {
            let windows = try parse(fetcher.fetch(timeout: 30))
            guard !windows.isEmpty else { throw UsageFetchError.unavailable }
            let snapshot = UsageSnapshot(provider: provider, revision: revision,
                                         collectedAt: milliseconds(), windows: windows)
            _ = try UsageWire().encode(snapshot, now: now())
            return UsageFetchResult(outcome: .refreshed, retryAt: nil, snapshot: snapshot)
        } catch let error as UsageFetchError {
            switch error {
            case .authenticationRequired:
                return UsageFetchResult(outcome: .authenticationRequired, retryAt: nil, snapshot: nil)
            case .temporaryFailure:
                return UsageFetchResult(outcome: .temporaryFailure, retryAt: nil, snapshot: nil)
            case .timeout:
                return UsageFetchResult(outcome: .timeout, retryAt: nil, snapshot: nil)
            case .unavailable:
                return UsageFetchResult(outcome: .usageUnavailable, retryAt: nil, snapshot: nil)
            case let .throttled(retryAt):
                return UsageFetchResult(outcome: .throttled, retryAt: retryAt, snapshot: nil)
            case .executableUnavailable:
                return UsageFetchResult(outcome: .executableUnavailable, retryAt: nil, snapshot: nil)
            }
        } catch {
            return UsageFetchResult(outcome: .temporaryFailure, retryAt: nil, snapshot: nil)
        }
    }

    private func statusCode(for outcome: UsageOutcome) -> UsageStatusCode {
        switch outcome {
        case .refreshed: .ready
        case .authenticationRequired: .authenticationRequired
        case .throttled: .throttled
        case .usageUnavailable: .usageUnavailable
        default: .temporaryFailure
        }
    }

    private func publish(snapshot: UsageSnapshot?, status: UsageCollectionStatus?) throws -> Bool {
        var attempted = false
        let wire = UsageWire()
        do {
            if let snapshot {
                let payload = try wire.encode(snapshot, now: now())
                attempted = true
                try notifier.post(name: Self.snapshotNotification, payload: payload)
            }
            if let status {
                let payload = try wire.encode(status, now: now())
                attempted = true
                try notifier.post(name: Self.statusNotification, payload: payload)
            }
        } catch {
            throw UsagePublicationError(attempted: attempted)
        }
        return attempted
    }

    private func milliseconds() -> Int64 {
        Int64(now().timeIntervalSince1970 * 1000)
    }

    private func status(
        _ code: UsageStatusCode, provider: UsageProvider, state: UsageProviderState, retryAt: Int64? = nil
    ) -> UsageCollectionStatus {
        UsageCollectionStatus(
            provider: provider, revision: state.revision, observedAt: milliseconds(), status: code, retryAt: retryAt,
            latestInvalidationRevision: state.latestInvalidationRevision
        )
    }

    private func result(
        _ provider: UsageProvider, _ outcome: UsageOutcome, retryAt: Int64? = nil,
        fresh: Bool = false, attempted: Bool = false
    ) -> UsageRefreshResult {
        UsageRefreshResult(provider: provider, outcome: outcome, retryAt: retryAt,
                           freshSnapshot: fresh, publicationAttempted: attempted)
    }
}

private struct UsagePublicationError: Error {
    let attempted: Bool
}
