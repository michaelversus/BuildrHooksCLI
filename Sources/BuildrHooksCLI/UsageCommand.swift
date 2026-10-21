import AppKit
import ArgumentParser
import BuildrHooksCore
import Darwin
import Foundation
import Synchronization

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
    @Option(name: .long, help: "Provider to clear (codex or claude). Explicit selection required.")
    var provider: [String] = []
    @Flag(name: .long, help: "Emit localCleared and publicationAttempted as JSON; no receiver acknowledgement.")
    var json = false

    func validate() throws {
        guard !provider.isEmpty, Set(provider).count == 1,
              provider.allSatisfy({ $0 == "codex" || $0 == "claude" }) else {
            throw ValidationError("Select one --provider codex or --provider claude.")
        }
    }

    enum CodingKeys: String, CodingKey { case provider, json }

    var makeExecution: (String?) -> UsageCommandExecution = UsageCommandExecution.init

    func run() throws {
        let execution = makeExecution(nil)
        defer { execution.close() }
        let runtime = execution.runtime
        guard let selected = provider.first.flatMap(UsageProvider.init(rawValue:)) else {
            throw ValidationError("Select --provider codex or --provider claude.")
        }
        let result = execution.coordination.clear(runtime: runtime, provider: selected, cancelled: runtime.isCancelled)
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
        var runtime = UsageRuntime(fetcher: CodexUsageFetcher(executablePath: codexPath), cliVersion: version)
        let state = lifecycle.state
        runtime.isCancelled = { state.cancelled }
        self.init(runtime: runtime, coordination: UsageCoordination())
        triggers = { state.takeTriggers() }
        wait = { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval($0)) }
        close = { lifecycle.close() }
    }
}

final class UsageWatchLifecycle {
    let state = UsageWatchState()
    private var recoveryObserver: NSObjectProtocol?
    private var signals: [DispatchSourceSignal] = []
    private var wakeObserver: NSObjectProtocol?
    private let signalNumbers: [Int32]
    private let recoveryCenter: NotificationCenter
    private let wakeCenter: NotificationCenter
    var cancelled: Bool {
        state.cancelled
    }

    init(
        signalNumbers: [Int32] = [SIGINT, SIGTERM],
        recoveryCenter: NotificationCenter = DistributedNotificationCenter.default(),
        wakeCenter: NotificationCenter = NSWorkspace.shared.notificationCenter
    ) {
        self.signalNumbers = signalNumbers
        self.recoveryCenter = recoveryCenter
        self.wakeCenter = wakeCenter
        let state = state
        for number in signalNumbers {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { state.stop() }
            source.resume()
            signals.append(source)
        }
        recoveryObserver = recoveryCenter.addObserver(
            forName: Notification.Name(UsageRuntime.requestNotification), object: nil, queue: nil
        ) { notification in
            if let userInfo = notification.userInfo {
                guard let request = try? UsageReplayRequest(userInfo: userInfo) else { return }
                state.requestClaudeRecovery(request.replayRequestID)
            } else {
                state.requestRecovery()
            }
        }
        wakeObserver = wakeCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { _ in state.wake() }
    }

    func takeTriggers() -> [UsageWatchTrigger] {
        state.takeTriggers()
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

/// Only this Sendable state crosses signal and notification callback boundaries.
/// Observer tokens and signal-source lifecycle stay with the synchronous command owner.
final class UsageWatchState: Sendable {
    private struct Flags {
        var stopped = false
        var woke = false
        var recoveryRequested = false
        var claudeRecoveryRequests: [String] = []
    }

    private let flags = Mutex(Flags())
    var cancelled: Bool {
        flags.withLock { $0.stopped }
    }

    func stop() {
        flags.withLock { $0.stopped = true }
    }

    func wake() {
        flags.withLock { $0.woke = true }
    }

    func requestRecovery() {
        flags.withLock { $0.recoveryRequested = true }
    }

    func requestClaudeRecovery(_ id: String) {
        flags.withLock {
            guard $0.claudeRecoveryRequests.count < 64, !$0.claudeRecoveryRequests.contains(id) else { return }
            $0.claudeRecoveryRequests.append(id)
        }
    }

    func takeTriggers() -> [UsageWatchTrigger] {
        flags.withLock { state in
            defer { state.woke = false; state.recoveryRequested = false; state.claudeRecoveryRequests = [] }
            var triggers: [UsageWatchTrigger] = state.woke ? [.wake] : []
            if state.recoveryRequested {
                triggers.append(.recoveryRequested)
            }
            triggers += state.claudeRecoveryRequests.map { .claudeRecoveryRequested($0) }
            return triggers
        }
    }
}
