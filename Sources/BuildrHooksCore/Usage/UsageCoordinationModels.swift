import Foundation

public enum UsageCoordinationError: Error { case unavailable }

public struct UsagePrivateRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case refresh, clear, ping }
    public var version = 1
    public var operation: Operation = .refresh
    public var provider: UsageProvider = .codex
    public init(operation: Operation = .refresh, provider: UsageProvider = .codex) {
        self.operation = operation
        self.provider = provider
    }
}

public extension UsageRuntime {
    /// Private commands execute synchronously under the collector ownership lock.
    func dispatch(_ request: UsagePrivateRequest) -> UsageRefreshResult {
        guard request.version == 1, request.provider == .codex else {
            return result(request.provider, .unsupportedProvider)
        }
        switch request.operation {
        case .refresh: return collect(provider: request.provider)
        case .clear: return clear(provider: request.provider)
        case .ping: return result(request.provider, .collectorRunning)
        }
    }
}
