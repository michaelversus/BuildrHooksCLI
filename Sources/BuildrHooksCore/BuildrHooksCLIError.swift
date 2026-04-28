import Foundation

public enum BuildrHooksCLIError: LocalizedError, Equatable {
    case unsupportedCommand([String])
    case unsupportedAgent(String)
    case unsupportedEvent(String)

    public var errorDescription: String? {
        switch self {
        case let .unsupportedCommand(components):
            "Unsupported BuildrHooksCLI command: \(components.joined(separator: " "))"
        case let .unsupportedAgent(agent):
            "Unsupported BuildrHooksCLI agent: \(agent)"
        case let .unsupportedEvent(event):
            "Unsupported BuildrHooksCLI event: \(event)"
        }
    }
}
