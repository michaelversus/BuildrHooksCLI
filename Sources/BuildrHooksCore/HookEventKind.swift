import Foundation

public enum HookEventKind: String, Codable, Equatable, Sendable {
    case sessionStart = "session-start"
    case promptSubmit = "prompt-submit"
    case stop
}
