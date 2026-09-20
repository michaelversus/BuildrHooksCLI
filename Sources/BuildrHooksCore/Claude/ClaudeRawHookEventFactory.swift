import Foundation

public enum ClaudeHookRelayError: Error, Equatable, LocalizedError {
    case invalidPayload

    public var errorDescription: String? {
        "Invalid Claude Code hook payload."
    }
}

public struct ClaudeRawHookEventFactory {
    private let parser: ClaudeHookPayloadParser
    private let gitContextReader: any HookGitContextReading
    private let executionSurfaceResolver: ClaudeTranscriptExecutionSurfaceResolver

    public init(
        parser: ClaudeHookPayloadParser = .init(),
        gitContextReader: any HookGitContextReading = FileSystemHookGitContextReader(),
        executionSurfaceResolver: ClaudeTranscriptExecutionSurfaceResolver = .init()
    ) {
        self.parser = parser
        self.gitContextReader = gitContextReader
        self.executionSurfaceResolver = executionSurfaceResolver
    }

    public func makeEvent(
        kind: HookEventKind,
        rawPayload: Data,
        createdAt: Date,
        currentWorkingDirectory: String,
        repositoryRoot: String
    ) throws -> RawHookEvent {
        let parsed = try parser.parse(kind: kind, data: rawPayload)
        let gitContext = gitContextReader.gitContext(repositoryRoot: repositoryRoot)
        return RawHookEvent(
            agentKind: .claude,
            eventKind: kind,
            createdAt: createdAt,
            currentWorkingDirectory: currentWorkingDirectory,
            repositoryRootPath: repositoryRoot,
            sessionID: parsed.sessionID,
            transcriptPath: parsed.transcriptPath,
            model: parsed.model,
            repositoryFingerprint: gitContext?.repositoryFingerprint,
            gitContext: gitContext,
            executionSurface: executionSurfaceResolver.resolveClaudeDesktopSurface(
                transcriptPath: parsed.transcriptPath,
                sessionID: parsed.sessionID
            ),
            rawPayload: String(bytes: rawPayload, encoding: .utf8) ?? ""
        )
    }
}
