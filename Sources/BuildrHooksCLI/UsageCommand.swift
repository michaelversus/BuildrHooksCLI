import AppKit
import ArgumentParser
import BuildrHooksCore
import Darwin
import Foundation

struct UsageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage", abstract: "Collect account usage independently of repository hooks.",
        subcommands: [UsageRefreshCommand.self, UsageWatchCommand.self, UsageClearCommand.self]
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

    func run() throws {
        let runtime = UsageRuntime(fetcher: CodexUsageFetcher(executablePath: codexPath))
        let lifecycle = UsageWatchLifecycle()
        defer { lifecycle.close() }
        let coordination = UsageCoordination()
        var ownedRuntime = runtime
        ownedRuntime.isCancelled = { lifecycle.cancelled }
        let result = coordination.refresh(runtime: ownedRuntime, cancelled: { lifecycle.cancelled })
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

    func run() throws {
        let runtime = UsageRuntime(fetcher: CodexUsageFetcher())
        let lifecycle = UsageWatchLifecycle()
        defer { lifecycle.close() }
        let result = UsageCoordination().clear(runtime: runtime, cancelled: { lifecycle.cancelled })
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

    func run() throws {
        let lifecycle = UsageWatchLifecycle()
        defer { lifecycle.close() }
        var runtime = UsageRuntime(fetcher: CodexUsageFetcher(executablePath: codexPath))
        runtime.isCancelled = { lifecycle.cancelled }
        let coordination = UsageCoordination()
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
        }, triggers: { lifecycle.takeTriggers() }, wait: {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval($0))
        })
    }
}

private final class UsageWatchLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var woke = false
    private var recoveryRequested = false
    private var recoveryObserver: NSObjectProtocol?
    private var signals: [DispatchSourceSignal] = []
    private var wakeObserver: NSObjectProtocol?
    var cancelled: Bool {
        lock.withLock { stopped }
    }

    init() {
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                lock.withLock { self.stopped = true }
            }
            source.resume()
            signals.append(source)
        }
        recoveryObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(UsageRuntime.requestNotification), object: nil, queue: nil
        ) { [weak self] notification in
            guard notification.userInfo == nil, let self else { return }
            lock.withLock { self.recoveryRequested = true }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
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
            DistributedNotificationCenter.default().removeObserver(recoveryObserver)
        }
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        signals.forEach { $0.cancel() }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_DFL)
        }
    }
}
