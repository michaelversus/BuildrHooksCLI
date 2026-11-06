import Foundation

/// Content-free terminal transport metadata. Kept after packet cleanup to fence late work.
/// Consumers must validate against the exact original request before changing app state.
public struct BridgeWorkflowTermination: Codable, Equatable, Sendable {
    public enum Disposition: String, Codable, Sendable { case completed, cancelled, timeout }

    public let version: Int
    public let requestID: String
    public let scope: BridgeScope
    public let createdAt: Double
    public let deadline: Double
    public let code: Disposition

    public init(version: Int = 1, requestID: String, scope: BridgeScope,
                createdAt: Double, deadline: Double, code: Disposition) {
        self.version = version
        self.requestID = requestID
        self.scope = scope
        self.createdAt = createdAt
        self.deadline = deadline
        self.code = code
    }
}

public extension BridgeValidator {
    static func validate(_ termination: BridgeWorkflowTermination, for request: BridgeRequest) throws {
        guard termination.version == 1 else { throw BridgeValidationError.incompatibleVersion }
        guard termination.requestID == request.requestID, termination.scope == request.scope,
              termination.createdAt == request.createdAt, termination.deadline == request.deadline else {
            throw BridgeValidationError.responseMismatch
        }
        try validate(termination.scope)
        try requireID(termination.requestID)
        guard termination.createdAt.isFinite, termination.deadline.isFinite,
              termination.createdAt >= 0, termination.deadline > termination.createdAt else {
            throw BridgeValidationError.invalidTime
        }
    }
}
