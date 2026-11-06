import Foundation

public enum BridgeOperation: String, Codable, CaseIterable, Sendable {
    case discover, resolve, prepare, finalize, cancel, recordCommit, recordRewrite, acknowledge
}

public struct BridgeCapabilities: Codable, Equatable, Sendable {
    public let protocolVersions: [Int]
    public let contractRevision: String
    public let definedOperations: [BridgeOperation]
    public let implementedOperations: [BridgeOperation]

    public init(protocolVersions: [Int], contractRevision: String,
                definedOperations: [BridgeOperation], implementedOperations: [BridgeOperation]) {
        self.protocolVersions = protocolVersions
        self.contractRevision = contractRevision
        self.definedOperations = definedOperations
        self.implementedOperations = implementedOperations
    }

    public static let current = BridgeCapabilities(
        protocolVersions: [1], contractRevision: "1.0.0",
        definedOperations: BridgeOperation.allCases, implementedOperations: []
    )

    public func negotiate(version: Int, operation: String) -> BridgeReadiness {
        guard protocolVersions.contains(version) else {
            return BridgeReadiness(status: .incompatible,
                                   action: "Use reporting/tracking protocol version 1 with a compatible app and CLI.")
        }
        guard let operation = BridgeOperation(rawValue: operation),
              definedOperations.contains(operation), implementedOperations.contains(operation) else {
            return BridgeReadiness(status: .unsupported,
                                   action: "Install a CLI/app pair implementing this operation. "
                                       + "Schema support alone is insufficient.")
        }
        return BridgeReadiness(status: .ready, action: "Operation is implemented; verify app setup and project access.")
    }
}

public struct BridgeReadiness: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ready, incompatible, unsupported
    }

    public let status: Status
    public let action: String

    public init(status: Status, action: String) {
        self.status = status
        self.action = action
    }
}
