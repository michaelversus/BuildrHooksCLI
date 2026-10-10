import AppKit
import ArgumentParser
import BuildrHooksCore
import Darwin
import Foundation

struct UsageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "usage", abstract: "Collect account usage independently of repository hooks.",
        subcommands: [UsageRefreshCommand.self, UsageWatchCommand.self]
    )
}

struct UsageRefreshCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "refresh", abstract: "Collect and attempt publication of a fresh Codex usage observation."
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
        let result = runtime.refresh(json: json)
        if result.outcome.exitCode != 0 {
            throw ExitCode(result.outcome.exitCode)
        }
    }
}

struct UsageWatchCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "watch", abstract: "Monitor Codex usage in the foreground until interrupted."
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

    func run() {
        let lifecycle = UsageWatchLifecycle()
        defer { lifecycle.close() }
        var runtime = UsageRuntime(fetcher: CodexUsageFetcher(executablePath: codexPath))
        runtime.isCancelled = { lifecycle.cancelled }
        runtime.watch(providers: [.codex], json: json, triggers: { lifecycle.takeTriggers() }, wait: {
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval($0))
        })
    }
}

private final class UsageWatchLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var woke = false
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
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            lock.withLock { self.woke = true }
        }
    }

    func takeTriggers() -> [UsageWatchTrigger] {
        lock.withLock {
            defer { woke = false }
            return woke ? [.wake] : []
        }
    }

    func close() {
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        signals.forEach { $0.cancel() }
        for number in [SIGINT, SIGTERM] {
            signal(number, SIG_DFL)
        }
    }
}
