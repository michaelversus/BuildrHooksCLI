import Foundation

/// Additive recovery envelope. A nil userInfo remains the legacy Codex request.
/// Correlation is an opaque bounded token, never proof of sender identity.
public struct UsageReplayRequest: Equatable, Sendable {
    public let replayRequestID: String

    public init(replayRequestID: String) throws {
        guard !replayRequestID.isEmpty, replayRequestID.utf8.count <= 128,
              replayRequestID.utf8.allSatisfy({
                  (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                      || [45, 46, 95].contains($0)
              }) else { throw UsageWireError.invalidPayload }
        self.replayRequestID = replayRequestID
    }

    public init(userInfo: [AnyHashable: Any]) throws {
        guard userInfo.count == 1, let value = userInfo["replayRequestID"] as? String else {
            throw UsageWireError.invalidPayload
        }
        try self.init(replayRequestID: value)
    }

    public var userInfo: [AnyHashable: Any] {
        ["replayRequestID": replayRequestID]
    }
}
