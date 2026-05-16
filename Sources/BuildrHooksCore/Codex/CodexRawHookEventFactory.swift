import Foundation

public enum CodexHookRelayError: Error, Equatable, LocalizedError {
    case invalidPayload

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            "Invalid Codex hook payload."
        }
    }
}

public struct CodexRawHookEventFactory {
    private let parser: CodexHookPayloadParser
    private let gitContextReader: any HookGitContextReading

    public init(
        parser: CodexHookPayloadParser = .init(),
        gitContextReader: any HookGitContextReading = FileSystemHookGitContextReader()
    ) {
        self.parser = parser
        self.gitContextReader = gitContextReader
    }

    public func makeEvent(
        kind: HookEventKind,
        rawPayload: Data,
        createdAt: Date,
        currentWorkingDirectory: String,
        repositoryRoot: String
    ) throws -> RawHookEvent {
        let rawString = String(bytes: rawPayload, encoding: .utf8) ?? ""
        let parsed = try parser.parse(kind: kind, data: rawPayload)
        let gitContext = gitContextReader.gitContext(repositoryRoot: repositoryRoot)
        return RawHookEvent(
            agentKind: .codex,
            eventKind: kind,
            createdAt: createdAt,
            currentWorkingDirectory: currentWorkingDirectory,
            repositoryRootPath: repositoryRoot,
            sessionID: parsed.sessionID,
            transcriptPath: parsed.transcriptPath,
            model: parsed.model,
            turnID: parsed.turnID,
            repositoryFingerprint: gitContext?.repositoryFingerprint,
            gitContext: gitContext,
            rawPayload: rawString
        )
    }
}
