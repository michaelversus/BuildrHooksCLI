import Foundation

public struct ExecutionSurface: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case terminal
        case desktop
    }

    public let kind: Kind
    public let instanceID: String

    public init(kind: Kind, instanceID: String) {
        self.kind = kind
        self.instanceID = instanceID
    }
}

public typealias CodexExecutionSurface = ExecutionSurface

public struct CodexTranscriptExecutionSurfaceResolver: Sendable {
    private let readFile: @Sendable (String) -> Data?

    public init(
        readFile: @escaping @Sendable (String) -> Data? = { path in
            try? Data(contentsOf: URL(filePath: path))
        }
    ) {
        self.readFile = readFile
    }

    public func resolve(transcriptPath: String?, sessionID: String) -> CodexExecutionSurface? {
        guard
            let transcriptPath,
            let data = readFile(transcriptPath),
            let transcript = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        for line in transcript.split(whereSeparator: \.isNewline) {
            guard
                let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                record["type"] as? String == "session_meta"
            else {
                continue
            }

            guard
                let payload = record["payload"] as? [String: Any],
                payload["session_id"] as? String == sessionID,
                let originator = payload["originator"] as? String
            else {
                return nil
            }

            if originator == "codex_cli_rs" {
                guard payload["source"] as? String == "cli" else {
                    return nil
                }
                return CodexExecutionSurface(kind: .terminal, instanceID: "codex-session:\(sessionID)")
            }

            return CodexExecutionSurface(kind: .desktop, instanceID: "codex-session:\(sessionID)")
        }

        return nil
    }
}
