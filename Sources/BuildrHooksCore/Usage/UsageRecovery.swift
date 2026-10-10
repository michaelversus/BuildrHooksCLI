import CryptoKit
import Foundation

/// Identity exists transiently at the provider boundary, never in the wire contract.
enum UsageAccountIdentity {
    static func fullObservation(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let identity = object["accountId"] as? String, !identity.isEmpty else { return nil }
        return identity
    }

    static func fingerprint(_ identity: String, salt: String) -> String {
        SHA256.hash(data: Data((salt + "\u{0}" + identity).utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// State is serialized by the synchronous runtime owner; the lock also protects injected callers.
final class UsageRecoverySession: @unchecked Sendable {
    private let lock = NSLock()
    private var verified = Set<UsageProvider>()
    private var lastReply: Int64?
    func verify(_ provider: UsageProvider) {
        lock.withLock { _ = verified.insert(provider) }
    }

    func unverify(_ provider: UsageProvider) {
        lock.withLock { _ = verified.remove(provider) }
    }

    func isVerified(_ provider: UsageProvider) -> Bool {
        lock.withLock { verified.contains(provider) }
    }

    func beginReply(at time: Int64) -> Bool {
        lock.withLock {
            if let lastReply, time < lastReply + 1000 {
                return false
            }
            lastReply = time
            return true
        }
    }
}

extension UsageRuntime {
    func reconcileIdentity(_ identity: String?, provider: UsageProvider, state: inout UsageProviderState) {
        guard let identity else { return }
        let salt = state.fingerprintSalt ?? UUID().uuidString
        let fingerprint = UsageAccountIdentity.fingerprint(identity, salt: salt)
        if let previous = state.accountFingerprint, previous != fingerprint {
            state.revision += 1
            state.latestInvalidationRevision = state.revision
            state.snapshot = nil
            recovery.unverify(provider)
        } else if state.snapshot != nil, state.accountFingerprint == nil {
            // Legacy observations have no proof of ownership.
            state.revision += 1
            state.latestInvalidationRevision = state.revision
            state.snapshot = nil
        }
        if state.accountFingerprint == fingerprint, state.snapshot != nil {
            recovery.verify(provider)
        }
        state.fingerprintSalt = salt
        state.accountFingerprint = fingerprint
    }

    /// Identity reads never fetch limits, and are bounded independently of collection scheduling.
    func prepareRecovery(providers: [UsageProvider], publishInvalidation: Bool = true) {
        for provider in providers where !recovery.isVerified(provider) {
            guard var durable = try? store.load(), var state = durable.providers[provider.rawValue],
                  state.revision < UInt64.max - 3 else { continue }
            let previousInvalidation = state.latestInvalidationRevision
            let adapter = additionalFetchers[provider] ?? fetcher
            let identity = try? adapter.currentAccountIdentity(timeout: 5)
            if let identity {
                let oldFingerprint = state.accountFingerprint
                reconcileIdentity(identity, provider: provider, state: &state)
                if oldFingerprint == state.accountFingerprint {
                    recovery.verify(provider)
                }
            }
            if !recovery.isVerified(provider), state.status?.status == .ready || state.status == nil {
                state.revision += 1
                state.status = status(.pending, provider: provider, state: state)
            } else if state.status?.latestInvalidationRevision != state.latestInvalidationRevision {
                state.revision += 1
                state.status = status(state.status?.status ?? .pending, provider: provider, state: state,
                                      retryAt: state.status?.retryAt)
            }
            durable.providers[provider.rawValue] = state
            do {
                try store.save(durable)
                if publishInvalidation, state.latestInvalidationRevision != previousInvalidation {
                    _ = try? publish(snapshot: nil, status: state.status)
                }
            } catch {
                recovery.unverify(provider)
                continue
            }
        }
    }

    /// Replay all selected providers at most once a second globally; no collection is triggered.
    public func recover(providers: [UsageProvider]) {
        guard recovery.beginReply(at: milliseconds()), !isCancelled() else { return }
        let selected = Array(Set(providers)).sorted { $0.rawValue < $1.rawValue }
        prepareRecovery(providers: selected, publishInvalidation: false)
        guard let durable = try? store.load() else { return }
        for provider in selected {
            guard let state = durable.providers[provider.rawValue] else { continue }
            let snapshot = recovery.isVerified(provider) ? state.snapshot : nil
            let valid = snapshot.flatMap { $0.revision > state.latestInvalidationRevision ? $0 : nil }
            _ = try? publish(snapshot: valid, status: state.status)
        }
    }
}
