import Foundation

public enum UsageFetchError: Error, Sendable {
    case authenticationRequired, temporaryFailure, timeout, unavailable
    case throttled(retryAt: Int64?)
    case executableUnavailable, cancelled
}

public protocol UsageFetching: Sendable {
    /// Implementations must honor this total fetch deadline, including initialization and authentication reads.
    func fetch(timeout: TimeInterval) throws -> Data
    func fetch(timeout: TimeInterval, isCancelled: @escaping @Sendable () -> Bool) throws -> Data
    func currentAccountIdentity(timeout: TimeInterval) throws -> String?
    func currentAccountIdentity(timeout: TimeInterval, isCancelled: @escaping @Sendable () -> Bool) throws -> String?
    func beginWatch()
    func events() throws -> [UsageWatchTrigger]
    func close()
}

public extension UsageFetching {
    func currentAccountIdentity(timeout: TimeInterval, isCancelled: @escaping @Sendable () -> Bool) throws -> String? {
        guard !isCancelled() else { throw UsageFetchError.cancelled }
        let identity = try currentAccountIdentity(timeout: timeout)
        guard !isCancelled() else { throw UsageFetchError.cancelled }
        return identity
    }

    func fetch(timeout: TimeInterval, isCancelled _: @escaping @Sendable () -> Bool) throws -> Data {
        try fetch(timeout: timeout)
    }

    func currentAccountIdentity(timeout _: TimeInterval) throws -> String? {
        nil
    }

    func beginWatch() {}
    func events() throws -> [UsageWatchTrigger] {
        []
    }

    func close() {}
}

public enum UsageWatchTrigger: Sendable, Equatable {
    case limitsChanged, authenticationChanged, wake, refresh, recoveryRequested
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
    case refreshed, cleared, invalidated
    case authenticationRequired = "authentication_required"
    case temporaryFailure = "temporary_failure"
    case throttled, timeout
    case usageUnavailable = "usage_unavailable"
    case persistenceFailure = "persistence_failure"
    case publicationFailure = "publication_failure"
    case executableUnavailable = "executable_unavailable"
    case cancelled
    case unsupportedProvider = "unsupported_provider"
    case collectorRunning = "collector_running"
    case coordinationUnavailable = "coordination_unavailable"
    public var exitCode: Int32 {
        switch self {
        case .refreshed, .cleared: 0
        case .invalidated: 22
        case .authenticationRequired: 10
        case .temporaryFailure: 11
        case .throttled: 12
        case .timeout: 13
        case .usageUnavailable: 14
        case .persistenceFailure: 15
        case .publicationFailure: 16
        case .executableUnavailable: 17
        case .cancelled: 18
        case .unsupportedProvider: 19
        case .collectorRunning: 20
        case .coordinationUnavailable: 21
        }
    }
}

public struct UsageRefreshResult: Codable, Sendable {
    public let provider: UsageProvider
    public let outcome: UsageOutcome
    public let retryAt: Int64?
    public let localCleared: Bool
    public let freshSnapshot: Bool
    public let publicationAttempted: Bool
    public init(provider: UsageProvider, outcome: UsageOutcome, retryAt: Int64?,
                freshSnapshot: Bool, publicationAttempted: Bool, localCleared: Bool = false) {
        self.localCleared = localCleared
        self.provider = provider
        self.outcome = outcome
        self.retryAt = retryAt
        self.freshSnapshot = freshSnapshot
        self.publicationAttempted = publicationAttempted
    }
}

/// Primary command, collection, and verified recovery seam.
public struct UsageRuntime: Sendable {
    public static let requestNotification = "ai.buildrai.account-usage-requested"
    let recovery = UsageRecoverySession()
    public static let snapshotNotification = "ai.buildrai.account-usage-updated"
    public static let statusNotification = "ai.buildrai.account-usage-status-updated"
    public var fetcher: any UsageFetching
    public var store: any UsageStateStoring
    public var notifier: any UsageNotifying
    public var now: @Sendable () -> Date
    public var parse: @Sendable (Data) throws -> [UsageWindow]
    public var jitter: @Sendable () -> Double = { Double.random(in: 0 ... 1) }
    public var isCancelled: @Sendable () -> Bool = { false }
    public var additionalFetchers: [UsageProvider: any UsageFetching] = [:]
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
        report(result, json: json)
        return result
    }

    public func report(_ result: UsageRefreshResult, json: Bool = false) {
        if json, let data = try? JSONEncoder().encode(result), let json = String(data: data, encoding: .utf8) {
            output(json)
        } else {
            let guidance = result.outcome == .executableUnavailable
                ? " Install Codex or provide an executable with --codex-path." : ""
            output("\(result.provider.rawValue) usage: \(result.outcome.rawValue). "
                + "Publication attempted: \(result.publicationAttempted)."
                + " Local cleared: \(result.localCleared). Receipt is not acknowledged." + guidance
                + (result.retryAt.map { " Retry at Unix milliseconds: \($0)." } ?? ""))
        }
    }

    /// One synchronous owner drives all triggers. Wait/clock/event sources are injectable;
    /// events carry no observation data and only request a full read.
    public func watch(
        providers: [UsageProvider], json: Bool = false,
        control: () -> Void = {},
        triggers: @Sendable () -> [UsageWatchTrigger] = { [] },
        wait: @Sendable (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        let selected = Array(Set(providers)).sorted { $0.rawValue < $1.rawValue }
        guard selected.allSatisfy({ $0 == .codex || additionalFetchers[$0] != nil }) else {
            output("Unsupported usage provider. Only Codex collection is implemented.")
            return
        }
        let fetchers = selected.map { additionalFetchers[$0] ?? fetcher }
        fetchers.forEach { $0.beginWatch() }
        defer { fetchers.forEach { $0.close() } }
        prepareRecovery(providers: selected)
        var pending = Set(selected)
        var nextPoll = Dictionary(uniqueKeysWithValues: selected.map { ($0, milliseconds()) })
        while !isCancelled() {
            control()
            let external = triggers()
            for provider in selected {
                processWatchProvider(provider, external: external, json: json, pending: &pending, nextPoll: &nextPoll)
            }
            if external.contains(.recoveryRequested) {
                recover(providers: selected)
            }
            if !isCancelled() {
                wait(0.1)
            }
        }
    }

    private func processWatchProvider(
        _ provider: UsageProvider, external: [UsageWatchTrigger], json: Bool,
        pending: inout Set<UsageProvider>, nextPoll: inout [UsageProvider: Int64]
    ) {
        let adapter = additionalFetchers[provider] ?? fetcher
        let events: [UsageWatchTrigger]
        do {
            events = try adapter.events()
        } catch {
            // A disconnected adapter reconnects on the next bounded full read.
            adapter.close()
            recovery.unverify(provider)
            pending.insert(provider)
            events = []
        }
        let all = external.filter { $0 != .recoveryRequested } + events
        if all.contains(.authenticationChanged) {
            recovery.unverify(provider)
            prepareRecovery(providers: [provider])
        }
        if all.contains(where: {
            if case .authenticationChanged = $0 {
                true
            } else {
                false
            }
        }) {
            pending.insert(provider)
        } else if !all.isEmpty {
            let status = try? store.load().providers[provider.rawValue]?.status?.status
            if status != .authenticationRequired || all.contains(.wake) {
                pending.insert(provider)
            }
        }
        if milliseconds() >= nextPoll[provider, default: 0] {
            pending.insert(provider)
        }
        guard pending.contains(provider), !isCancelled() else { return }
        let state = try? store.load().providers[provider.rawValue]
        let allowed = max(
            (state?.lastFetchStartedAt ?? (milliseconds() - 30000)) + 30000,
            state?.retryNotBefore ?? 0
        )
        guard milliseconds() >= allowed else { return }
        pending.remove(provider)
        let outcome = refresh(provider: provider, json: json)
        nextPoll[provider] = milliseconds() + 300_000
        if shouldRetry(outcome.outcome) {
            pending.insert(provider)
        }
    }

    private func shouldRetry(_ outcome: UsageOutcome) -> Bool {
        outcome == .temporaryFailure || outcome == .timeout || outcome == .throttled
            || outcome == .executableUnavailable
    }

    func collect(provider: UsageProvider) -> UsageRefreshResult {
        guard provider == .codex || additionalFetchers[provider] != nil else {
            return result(provider, .unsupportedProvider)
        }
        var durable: UsageDurableState
        do { durable = try store.load() } catch { return result(provider, .persistenceFailure) }
        var state = durable.providers[provider.rawValue] ?? .init()
        guard !isCancelled() else { return result(provider, .cancelled) }
        let spacing = (state.lastFetchStartedAt ?? (milliseconds() - 30000)) + 30000
        let restriction = max(spacing, state.retryNotBefore ?? 0)
        guard milliseconds() >= restriction else {
            return result(provider, .throttled, retryAt: restriction)
        }
        state.lastFetchStartedAt = milliseconds()
        guard state.revision < UInt64.max - 3 else { return result(provider, .persistenceFailure) }
        state.revision += 1
        state.status = status(.pending, provider: provider, state: state)
        durable.providers[provider.rawValue] = state
        do { try store.save(durable) } catch { return result(provider, .persistenceFailure) }
        guard !isCancelled() else { return result(provider, .cancelled) }
        publishPendingStatus(state.status)
        let fetched = fetch(provider: provider, revision: state.revision + 1)
        guard !isCancelled(), fetched.outcome != .cancelled else { return result(provider, .cancelled) }
        // Reload after the injected provider boundary: a clear invalidates the whole older fetch.
        do {
            durable = try store.load()
            guard let current = durable.providers[provider.rawValue], current.revision == state.revision else {
                return result(provider, .invalidated)
            }
            state = current
        } catch { return result(provider, .persistenceFailure) }
        let outcome = fetched.outcome
        let retryAt = retryAt(for: outcome, fetchedRetryAt: fetched.retryAt, state: &state)
        let completion = UsageCompletion(provider: provider, fetched: fetched, outcome: outcome, retryAt: retryAt)
        return finish(completion, state: &state, durable: &durable)
    }

    private func publishPendingStatus(_ status: UsageCollectionStatus?) {
        guard let status, let payload = try? UsageWire().encode(status, now: now()) else { return }
        try? notifier.post(name: Self.statusNotification, payload: payload)
    }

    private func fetch(provider: UsageProvider, revision: UInt64) -> UsageFetchResult {
        var identity: String?
        do {
            guard !isCancelled() else { throw UsageFetchError.cancelled }
            let selected = additionalFetchers[provider] ?? fetcher
            let data = try selected.fetch(timeout: 30, isCancelled: isCancelled)
            identity = UsageAccountIdentity.fullObservation(data)
            let windows = try parse(data)
            guard !windows.isEmpty else {
                return UsageFetchResult(outcome: .usageUnavailable, retryAt: nil, snapshot: nil, identity: identity)
            }
            let snapshot = UsageSnapshot(provider: provider, revision: revision,
                                         collectedAt: milliseconds(), windows: windows)
            _ = try UsageWire().encode(snapshot, now: now())
            return UsageFetchResult(outcome: .refreshed, retryAt: nil, snapshot: snapshot, identity: identity)
        } catch let error as UsageFetchError {
            return usageFetchResult(for: error, identity: identity)
        } catch {
            return UsageFetchResult(outcome: .temporaryFailure, retryAt: nil, snapshot: nil, identity: identity)
        }
    }

    func publish(snapshot: UsageSnapshot?, status: UsageCollectionStatus?) throws -> Bool {
        var attempted = false
        let wire = UsageWire()
        do {
            if let snapshot {
                guard !isCancelled() else { throw UsageFetchError.cancelled }
                let payload = try wire.encode(snapshot, now: now())
                attempted = true
                try notifier.post(name: Self.snapshotNotification, payload: payload)
            }
            if let status {
                guard !isCancelled() else { throw UsageFetchError.cancelled }
                let payload = try wire.encode(status, now: now())
                attempted = true
                try notifier.post(name: Self.statusNotification, payload: payload)
            }
        } catch {
            throw UsagePublicationError(attempted: attempted)
        }
        return attempted
    }

    func milliseconds() -> Int64 {
        Int64(now().timeIntervalSince1970 * 1000)
    }

    func status(
        _ code: UsageStatusCode, provider: UsageProvider, state: UsageProviderState, retryAt: Int64? = nil
    ) -> UsageCollectionStatus {
        UsageCollectionStatus(
            provider: provider, revision: state.revision, observedAt: milliseconds(), status: code, retryAt: retryAt,
            latestInvalidationRevision: state.latestInvalidationRevision
        )
    }

    func result(
        _ provider: UsageProvider, _ outcome: UsageOutcome, retryAt: Int64? = nil,
        fresh: Bool = false, attempted: Bool = false
    ) -> UsageRefreshResult {
        UsageRefreshResult(provider: provider, outcome: outcome, retryAt: retryAt,
                           freshSnapshot: fresh, publicationAttempted: attempted)
    }
}

private func usageFetchResult(for error: UsageFetchError, identity: String?) -> UsageFetchResult {
    let outcome: UsageOutcome
    let retryAt: Int64?
    switch error {
    case .authenticationRequired:
        outcome = .authenticationRequired
        retryAt = nil
    case .temporaryFailure:
        outcome = .temporaryFailure
        retryAt = nil
    case .timeout:
        outcome = .timeout
        retryAt = nil
    case .unavailable:
        outcome = .usageUnavailable
        retryAt = nil
    case let .throttled(value):
        outcome = .throttled
        retryAt = value
    case .cancelled:
        outcome = .cancelled
        retryAt = nil
    case .executableUnavailable:
        outcome = .executableUnavailable
        retryAt = nil
    }
    return UsageFetchResult(outcome: outcome, retryAt: retryAt, snapshot: nil, identity: identity)
}
