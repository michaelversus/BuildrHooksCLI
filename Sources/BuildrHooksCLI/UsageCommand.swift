import AppKit
import ArgumentParser
import BuildrHooksCore
import Darwin
import Foundation

struct UsageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage", abstract: "Collect account usage independently of repository hooks.",
        subcommands: [
            UsageRefreshCommand.self, UsageWatchCommand.self, UsageClearCommand.self, UsageServiceCommand.self
        ]
    )
}

struct UsageRefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh",
        abstract: "Collect fresh usage, delegating to the single running collector when available."
    )
    @Option(name: .long, help: "Provider to collect (codex). May be repeated.")
    var provider: [String] = []
    @Option(name: .long, help: "Absolute path to an installed Codex executable.")
    var codexPath: String?
    @Flag(name: .long, help: "Emit the actual outcome as JSON.")
    var json = false
    func validate() throws {
        guard !provider.isEmpty, provider.allSatisfy({ $0 == "codex" }) else {
            throw ValidationError("Select --provider codex. Only Codex usage is supported.")
        }
    }

    enum CodingKeys: String, CodingKey { case provider, codexPath, json }

    var makeExecution: (String?) -> UsageCommandExecution = UsageCommandExecution.init

    func run() throws {
        let execution = makeExecution(codexPath)
        defer { execution.close() }
        let runtime = execution.runtime
        let result = execution.coordination.refresh(runtime: runtime, cancelled: runtime.isCancelled)
        runtime.report(result, json: json)
        if result.outcome.exitCode != 0 {
            throw ExitCode(result.outcome.exitCode)
        }
    }
}

struct UsageClearCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Discard retained usage without stopping collection; receipt is not acknowledged."
    )
    @Option(name: .long, help: "Provider to clear (codex). Explicit selection required.")
    var provider: [String] = []
    @Flag(name: .long, help: "Emit localCleared and publicationAttempted as JSON; no receiver acknowledgement.")
    var json = false

    func validate() throws {
        guard !provider.isEmpty, provider.allSatisfy({ $0 == "codex" }) else {
            throw ValidationError("Select --provider codex. Only Codex usage is supported.")
        }
    }

    enum CodingKeys: String, CodingKey { case provider, json }

    var makeExecution: (String?) -> UsageCommandExecution = UsageCommandExecution.init

    func run() throws {
        let execution = makeExecution(nil)
        defer { execution.close() }
        let runtime = execution.runtime
        let result = execution.coordination.clear(runtime: runtime, cancelled: runtime.isCancelled)
        runtime.report(result, json: json)
        if result.outcome.exitCode != 0 {
            throw ExitCode(result.outcome.exitCode)
        }
    }
}

struct UsageWatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch",
        abstract: "Monitor Codex usage as the single collector; exit if another collector owns it."
    )
    @Option(name: .long, help: "Provider to collect (codex). May be repeated; collected once.")
    var provider: [String] = []
    @Option(name: .long, help: "Absolute path to an installed Codex executable.")
    var codexPath: String?
    @Flag(name: .long, help: "Emit fresh fetch outcomes as JSON; publication does not acknowledge receipt.")
    var json = false

    func validate() throws {
        guard !provider.isEmpty, provider.allSatisfy({ $0 == "codex" }) else {
            throw ValidationError("Select --provider codex. Only Codex usage is supported.")
        }
    }

    enum CodingKeys: String, CodingKey { case provider, codexPath, json }

    var makeExecution: (String?) -> UsageCommandExecution = UsageCommandExecution.init

    func run() throws {
        let execution = makeExecution(codexPath)
        defer { execution.close() }
        let runtime = execution.runtime
        let coordination = execution.coordination
        defer { coordination.close() }
        do {
            guard try coordination.acquire() else {
                runtime.report(
                    UsageRefreshResult(provider: .codex, outcome: .collectorRunning,
                                       retryAt: nil, freshSnapshot: false, publicationAttempted: false),
                    json: json
                )
                FileHandle.standardError.write(Data("A usage collector is already running. Use usage refresh.\n".utf8))
                throw ExitCode(UsageOutcome.collectorRunning.exitCode)
            }
            try coordination.startServing()
        } catch let code as ExitCode {
            throw code
        } catch {
            runtime.report(
                UsageRefreshResult(provider: .codex, outcome: .coordinationUnavailable,
                                   retryAt: nil, freshSnapshot: false, publicationAttempted: false),
                json: json
            )
            throw ExitCode(UsageOutcome.coordinationUnavailable.exitCode)
        }
        runtime.watch(providers: [.codex], json: json, control: {
            coordination.serve { runtime.dispatch($0) }
        }, triggers: execution.triggers, wait: execution.wait)
    }
}

/// Per-invocation dependencies keep command tests away from real account state and signal handlers.
struct UsageCommandExecution {
    var runtime: UsageRuntime
    var coordination: UsageCoordination
    var triggers: @Sendable () -> [UsageWatchTrigger] = { [] }
    var wait: @Sendable (TimeInterval) -> Void = { _ in }
    var close: () -> Void = {}

    init(runtime: UsageRuntime, coordination: UsageCoordination) {
        self.runtime = runtime
        self.coordination = coordination
    }

    init(codexPath: String?) {
        let lifecycle = UsageWatchLifecycle()
        var runtime = UsageRuntime(fetcher: CodexUsageFetcher(executablePath: codexPath))
        runtime.isCancelled = { lifecycle.cancelled }
        self.init(runtime: runtime, coordination: UsageCoordination())
        triggers = { lifecycle.takeTriggers() }
        wait = { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval($0)) }
        close = { lifecycle.close() }
    }
}

final class UsageWatchLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var woke = false
    private var recoveryRequested = false
    private var recoveryObserver: NSObjectProtocol?
    private var signals: [DispatchSourceSignal] = []
    private var wakeObserver: NSObjectProtocol?
    private let signalNumbers: [Int32]
    private let recoveryCenter: NotificationCenter
    private let wakeCenter: NotificationCenter
    var cancelled: Bool {
        lock.withLock { stopped }
    }

    init(
        signalNumbers: [Int32] = [SIGINT, SIGTERM],
        recoveryCenter: NotificationCenter = DistributedNotificationCenter.default(),
        wakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.signalNumbers = signalNumbers
        self.recoveryCenter = recoveryCenter
        self.wakeCenter = wakeCenter
        for number in signalNumbers {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                lock.withLock { self.stopped = true }
            }
            source.resume()
            signals.append(source)
        }
        recoveryObserver = recoveryCenter.addObserver(
            forName: Notification.Name(UsageRuntime.requestNotification), object: nil, queue: nil
        ) { [weak self] notification in
            guard notification.userInfo == nil, let self else { return }
            lock.withLock { self.recoveryRequested = true }
        }
        wakeObserver = wakeCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            lock.withLock { self.woke = true }
        }
    }

    func takeTriggers() -> [UsageWatchTrigger] {
        lock.withLock {
            defer { woke = false; recoveryRequested = false }
            var triggers: [UsageWatchTrigger] = woke ? [.wake] : []
            if recoveryRequested {
                triggers.append(.recoveryRequested)
            }
            return triggers
        }
    }

    func close() {
        if let recoveryObserver {
            recoveryCenter.removeObserver(recoveryObserver)
        }
        if let wakeObserver {
            wakeCenter.removeObserver(wakeObserver)
        }
        signals.forEach { $0.cancel() }
        for number in signalNumbers {
            signal(number, SIG_DFL)
        }
    }
}
