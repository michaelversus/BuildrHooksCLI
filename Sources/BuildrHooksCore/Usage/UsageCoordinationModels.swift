import Foundation

public enum UsageCoordinationError: Error { case unavailable }

public struct UsagePrivateRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case refresh, clear, ping, capture }
    public var version = 1
    public var operation: Operation = .refresh
    public var provider: UsageProvider = .codex
    public var windows: [UsageWindow]?
    public var generation: UInt64?
    public init(operation: Operation = .refresh, provider: UsageProvider = .codex) {
        self.operation = operation
        self.provider = provider
    }

    public init(windows: [UsageWindow]?, generation: UInt64) {
        operation = .capture
        provider = .claude
        self.windows = windows
        self.generation = generation
    }
}

public extension UsageRuntime {
    /// Private commands execute synchronously under the collector ownership lock.
    func dispatch(_ request: UsagePrivateRequest) -> UsageRefreshResult {
        guard request.version == 1 else {
            return result(request.provider, .unsupportedProvider)
        }
        switch request.operation {
        case .refresh: return collect(provider: request.provider)
        case .clear: return clear(provider: request.provider)
        case .ping: return result(request.provider, .collectorRunning)
        case .capture:
            guard request.provider == .claude, let generation = request.generation else {
                return result(request.provider, .unsupportedProvider)
            }
            return acceptClaude(windows: request.windows, generation: generation)
        }
    }
}
