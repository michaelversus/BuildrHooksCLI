import Foundation

public struct BuildrHooksCLIEntrypoint {
    public var standardInputProvider: @Sendable () -> Data
    public var standardErrorWriter: @Sendable (String) -> Void
    public var currentWorkingDirectoryProvider: @Sendable () -> String
    public var now: @Sendable () -> Date
    public var repositoryRootLocator: RepositoryRootLocator
    public var queue: RawHookEventQueue
    public var notifier: any HookEventNotifying

    public init(
        standardInputProvider: @escaping @Sendable () -> Data = {
            FileHandle.standardInput.readDataToEndOfFile()
        },
        standardErrorWriter: @escaping @Sendable (String) -> Void = { message in
            fputs("\(message)\n", stderr)
        },
        currentWorkingDirectoryProvider: @escaping @Sendable () -> String = {
            FileManager.default.currentDirectoryPath
        },
        now: @escaping @Sendable () -> Date = Date.init,
        repositoryRootLocator: RepositoryRootLocator = .init(),
        queue: RawHookEventQueue = .init(),
        notifier: any HookEventNotifying = DistributedHookEventNotifier()
    ) {
        self.standardInputProvider = standardInputProvider
        self.standardErrorWriter = standardErrorWriter
        self.currentWorkingDirectoryProvider = currentWorkingDirectoryProvider
        self.now = now
        self.repositoryRootLocator = repositoryRootLocator
        self.queue = queue
        self.notifier = notifier
    }

    public func run(arguments: [String]) throws {
        let components = Array(arguments.dropFirst())
        guard components.count == 2 else {
            throw BuildrHooksCLIError.unsupportedCommand(components)
        }

        switch components[0] {
        case HookAgentKind.codex.rawValue:
            let kind = try hookEventKind(for: components[1])
            let payload = standardInputProvider()
            let cwd = currentWorkingDirectoryProvider()
            let repositoryRootURL = repositoryRootLocator.repositoryRoot(startingAt: cwd)

            do {
                let event = try CodexRawHookEventFactory().makeEvent(
                    kind: kind,
                    rawPayload: payload,
                    createdAt: now(),
                    currentWorkingDirectory: cwd,
                    repositoryRoot: repositoryRootURL.path
                )
                _ = try queue.enqueue(event, in: repositoryRootURL)
                notifier.postHookEventEnqueued(repositoryRootPath: repositoryRootURL.path)
            } catch {
                standardErrorWriter("BuildrHooksCLI warning: \(error.localizedDescription)")
            }
        default:
            throw BuildrHooksCLIError.unsupportedAgent(components[0])
        }
    }

    private func hookEventKind(for value: String) throws -> HookEventKind {
        guard let kind = HookEventKind(rawValue: value) else {
            throw BuildrHooksCLIError.unsupportedEvent(value)
        }
        return kind
    }
}
