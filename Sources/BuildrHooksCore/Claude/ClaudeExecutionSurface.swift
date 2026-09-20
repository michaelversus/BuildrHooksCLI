import Foundation

public struct ClaudeTranscriptExecutionSurfaceResolver: Sendable {
    private let readFile: @Sendable (String) -> Data?

    public init(
        readFile: @escaping @Sendable (String) -> Data? = { try? Data(contentsOf: URL(filePath: $0)) }
    ) {
        self.readFile = readFile
    }

    public func resolveClaudeDesktopSurface(transcriptPath: String?, sessionID: String) -> ExecutionSurface? {
        guard
            let transcriptPath,
            let data = readFile(transcriptPath),
            let transcript = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        var latestEntrypoint: String?
        for line in transcript.split(whereSeparator: \.isNewline) {
            guard
                let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                record["sessionId"] as? String == sessionID,
                let entrypoint = record["entrypoint"] as? String
            else {
                continue
            }
            latestEntrypoint = entrypoint
        }

        guard latestEntrypoint == "claude-desktop" else { return nil }
        return ExecutionSurface(kind: .desktop, instanceID: "claude-session:\(sessionID)")
    }
}
