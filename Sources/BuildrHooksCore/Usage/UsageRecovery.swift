import CryptoKit
import Foundation
import Synchronization

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

/// The synchronous collector and callback bridges access recovery state through one mutex.
final class UsageRecoverySession: Sendable {
    private struct State {
        var verified = Set<UsageProvider>()
        var lastReply: Int64?
        var correlatedReplies: [String: Int64] = [:]
    }

    private let state = Mutex(State())

    func verify(_ provider: UsageProvider) {
        state.withLock { _ = $0.verified.insert(provider) }
    }

    func unverify(_ provider: UsageProvider) {
        state.withLock { _ = $0.verified.remove(provider) }
    }

    func isVerified(_ provider: UsageProvider) -> Bool {
        state.withLock { $0.verified.contains(provider) }
    }

    func beginClaudeReply(id: String, at time: Int64) -> Bool {
        state.withLock {
            if let last = $0.correlatedReplies[id], time < last + 1000 {
                return false
            }
            $0.correlatedReplies = $0.correlatedReplies.filter { time < $0.value + 1000 }
            guard $0.correlatedReplies.count < 64 else { return false }
            $0.correlatedReplies[id] = time
            return true
        }
    }

    func beginReply(at time: Int64) -> Bool {
        state.withLock {
            if let lastReply = $0.lastReply, time < lastReply + 1000 {
                return false
            }
            $0.lastReply = time
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
        for provider in providers where provider == .codex && !recovery.isVerified(provider) {
            guard !isCancelled() else { return }
            guard var durable = try? store.load(), var state = durable.providers[provider.rawValue],
                  state.revision < UInt64.max - 3, state.snapshot != nil else { continue }
            let previousInvalidation = state.latestInvalidationRevision
            let adapter = additionalFetchers[provider] ?? fetcher
            let identity = try? adapter.currentAccountIdentity(timeout: 5, isCancelled: isCancelled)
            guard !isCancelled() else { return }
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
    public func recover(providers: [UsageProvider], replayRequestID: String? = nil) {
        guard !isCancelled() else { return }
        if let replayRequestID {
            guard (try? UsageReplayRequest(replayRequestID: replayRequestID)) != nil,
                  recovery.beginClaudeReply(id: replayRequestID, at: milliseconds()) else { return }
        } else {
            guard recovery.beginReply(at: milliseconds()) else { return }
        }
        let selected = Array(Set(providers)).sorted { $0.rawValue < $1.rawValue }
        prepareRecovery(providers: selected, publishInvalidation: false)
        guard let durable = try? store.load() else { return }
        for provider in selected {
            if provider == .claude {
                recoverClaude(replayRequestID: replayRequestID)
                continue
            }
            guard let state = durable.providers[provider.rawValue] else { continue }
            let snapshot = recovery.isVerified(provider) ? state.snapshot : nil
            let valid = snapshot.flatMap { $0.revision > state.latestInvalidationRevision ? $0 : nil }
            _ = try? publish(snapshot: valid, status: state.status)
        }
    }
}

extension UsageRuntime {
    /// Called by an existing owner; no provider identity or quota read is performed.
    private func recoverClaude(replayRequestID: String?) {
        guard let cliVersion, var durable = try? store.load() else { return }
        var state = durable.providers[UsageProvider.claude.rawValue] ?? .init()
        if state.status == nil {
            guard state.revision < UInt64.max else { return }
            state.revision += 1
            state.status = UsageCollectionStatus(revision: state.revision, observedAt: milliseconds(),
                                                 status: .usageUnavailable,
                                                 latestInvalidationRevision: state.latestInvalidationRevision,
                                                 retainedSnapshotRevision: nil, cliVersion: cliVersion)
            durable.providers[UsageProvider.claude.rawValue] = state
            guard (try? store.save(durable)) != nil else { return }
        }
        var snapshot = state.snapshot
        var status = state.status
        snapshot?.replayRequestID = replayRequestID
        status?.replayRequestID = replayRequestID
        _ = try? publish(snapshot: snapshot, status: status)
    }
}
