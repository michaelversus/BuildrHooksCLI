import Darwin
import Foundation

public struct UsageServiceProcessState: Sendable {
    public var loaded: Bool
    public var running: Bool
    public init(loaded: Bool, running: Bool) {
        self.loaded = loaded; self.running = running
    }
}

/// Injection boundary: ordinary tests never contact launchd or install a real service.
public protocol UsageServiceManaging: Sendable {
    func inspect(label: String) throws -> UsageServiceProcessState
    func start(label: String, plist: URL) throws
    func stop(label: String) throws
    func inspect(label: String, timeout: TimeInterval) throws -> UsageServiceProcessState
    func stop(label: String, timeout: TimeInterval) throws
}

public extension UsageServiceManaging {
    func inspect(label: String, timeout _: TimeInterval) throws -> UsageServiceProcessState {
        try inspect(label: label)
    }

    func stop(label: String, timeout _: TimeInterval) throws {
        try stop(label: label)
    }
}

public struct UsageLaunchctl: UsageServiceManaging {
    public init() {}
    private var domain: String {
        "gui/\(geteuid())"
    }

    public func inspect(label: String) throws -> UsageServiceProcessState {
        try inspect(label: label, timeout: 5)
    }

    public func inspect(label: String, timeout: TimeInterval) throws -> UsageServiceProcessState {
        let (code, output) = try run(["print", "\(domain)/\(label)"], timeout: timeout)
        if code == 113 {
            return .init(loaded: false, running: false)
        }
        guard code == 0 else { throw UsageServiceError.launchctlUnavailable }
        return .init(loaded: true, running: output.contains("state = running"))
    }

    public func start(label _: String, plist: URL) throws {
        guard try run(["bootstrap", domain, plist.path]).0 == 0 else {
            throw UsageServiceError.launchctlUnavailable
        }
    }

    public func stop(label: String) throws {
        try stop(label: label, timeout: 5)
    }

    public func stop(label: String, timeout: TimeInterval) throws {
        let code = try run(["bootout", "\(domain)/\(label)"], timeout: timeout).0
        guard code == 0 || code == 113 else {
            throw UsageServiceError.launchctlUnavailable
        }
    }

    private func run(_ arguments: [String], timeout: TimeInterval = 5) throws -> (Int32, String) {
        guard timeout > 0 else { throw UsageServiceError.shutdownPending }
        let deadline = ProcessInfo.processInfo.systemUptime + min(5, timeout)
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw UsageServiceError.launchctlUnavailable }
        // Drain concurrently so launchctl print cannot block on a full pipe.
        let reader = ServiceOutputReader(pipe: output)
        reader.start()
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning {
            Darwin.kill(process.processIdentifier, SIGKILL)
            // Foundation owns/reaps this child; only our launchctl invocation is signalled.
            throw UsageServiceError.launchctlUnavailable
        }
        guard let result = reader.finish(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)) else {
            throw UsageServiceError.launchctlUnavailable
        }
        return (process.terminationStatus, result)
    }
}

private final class ServiceOutputReader: @unchecked Sendable {
    let pipe: Pipe
    let group = DispatchGroup()
    let lock = NSLock()
    var data = Data()
    init(pipe: Pipe) {
        self.pipe = pipe
    }

    func start() {
        group.enter()
        DispatchQueue.global().async { [self] in
            let result = pipe.fileHandleForReading.readDataToEndOfFile()
            lock.withLock { data = result }
            group.leave()
        }
    }

    func finish(timeout: TimeInterval) -> String? {
        guard group.wait(timeout: .now() + timeout) == .success else { return nil }
        return lock.withLock { String(data: data, encoding: .utf8) ?? "" }
    }
}

public enum UsageServiceError: String, Error, Codable {
    case invalidProvider = "invalid_provider"
    case cliExecutableUnavailable = "cli_executable_unavailable"
    case codexExecutableUnavailable = "codex_executable_unavailable"
    case foregroundConflict = "foreground_conflict"
    case launchctlUnavailable = "launchctl_unavailable"
    case invalidConfiguration = "invalid_configuration"
    case shutdownPending = "shutdown_pending"
    case managementBusy = "management_busy"
    public var guidance: String {
        switch self {
        case .invalidProvider: "Select --provider codex explicitly."
        case .cliExecutableUnavailable: "Install buildrhooks at a stable absolute path or pass --cli-path."
        case .codexExecutableUnavailable:
            "Install Codex yourself or pass --codex-path with an absolute executable path."
        case .foregroundConflict: "Stop the foreground usage watch before enabling the service."
        case .launchctlUnavailable: "Check your user login session and launchctl access; inspect usage service status."
        case .invalidConfiguration: "Disable the service and enable it again with valid executable paths."
        case .shutdownPending: "Collector shutdown is still pending. Retry after it exits."
        case .managementBusy: "Another service management command is running. Retry shortly."
        }
    }
}

public struct UsageServiceStatus: Codable, Sendable {
    public let configured: Bool
    public let installed: Bool
    public let enabledProviders: [UsageProvider]
    public let processRunning: Bool
    public let collectorAvailable: Bool
    public let executablesValid: Bool
    public let processHealth: UsageServiceHealth
    /// Historical, committed status; it does not establish current process health.
    public let retainedCollectionStatus: [UsageCollectionStatus]
}

/// Service diagnostics only; these are not collection notification status codes.
public enum UsageServiceHealth: String, Codable, Sendable {
    case configured, enabled, restarting, unavailable, stopped
}

public struct UsageService {
    public static let label = "ai.buildrai.account-usage"
    public let plistURL: URL
    public let cacheURL: URL
    public var manager: any UsageServiceManaging
    public var collectorAvailable: () -> Bool
    public var collectorIdle: () throws -> Bool
    public var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    public var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                cacheURL: URL = UsageFileStateStore().fileURL,
                manager: any UsageServiceManaging = UsageLaunchctl()) {
        plistURL = home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
        self.cacheURL = cacheURL
        self.manager = manager
        collectorAvailable = { UsageCoordination(cacheURL: cacheURL).available() }
        collectorIdle = {
            let coordination = UsageCoordination(cacheURL: cacheURL)
            defer { coordination.close() }
            return try coordination.acquire()
        }
    }

    public func status() throws -> UsageServiceStatus {
        try status(process: nil)
    }

    private func status(
        process knownProcess: UsageServiceProcessState?, probe: Bool = true
    ) throws -> UsageServiceStatus {
        let configuration = try readConfiguration()
        let process = try knownProcess ?? manager.inspect(label: Self.label)
        let state = try UsageFileStateStore(fileURL: cacheURL).load()
        let available = probe && collectorAvailable()
        let valid = configuration.map { validExecutable($0[0]) && validExecutable($0[6]) } ?? false
        let health: UsageServiceHealth
        if configuration == nil, !process.loaded {
            health = .stopped
        } else if !valid || (process.running && !available) {
            health = .unavailable
        } else if !process.loaded {
            health = .configured
        } else if !process.running {
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil)
                as? [String: Any]
            health = plist?["KeepAlive"] as? Bool == true ? .restarting : .stopped
        } else {
            health = .enabled
        }
        return UsageServiceStatus(
            configured: configuration != nil, installed: process.loaded,
            enabledProviders: configuration == nil ? [] : [.codex], processRunning: process.running,
            collectorAvailable: available, executablesValid: valid, processHealth: health,
            retainedCollectionStatus: state.providers.values.compactMap(\.status).sorted {
                $0.provider.rawValue < $1.provider.rawValue
            }
        )
    }

    public func enable(
        providers: [String], cliPath: String?, codexPath: String?, currentExecutable: String = CommandLine.arguments[0],
        searchPath: String = ProcessInfo.processInfo.environment["PATH"] ?? ""
    ) throws -> UsageServiceStatus {
        try withManagementLock {
            guard !providers.isEmpty, providers.allSatisfy({ $0 == "codex" }) else {
                throw UsageServiceError.invalidProvider
            }
            let previous = try readConfiguration()
            let cli = cliPath ?? previous?[0] ?? currentExecutable
            let codex = codexPath ?? previous?[6] ?? searchPath.split(separator: ":")
                .filter { $0.hasPrefix("/") }.map { "\($0)/codex" }.first(where: validExecutable) ?? ""
            guard validExecutable(cli) else { throw UsageServiceError.cliExecutableUnavailable }
            guard validExecutable(codex) else { throw UsageServiceError.codexExecutableUnavailable }
            let process = try manager.inspect(label: Self.label)
            if !process.running, try !collectorIdle() {
                throw UsageServiceError.foregroundConflict
            }
            if process.loaded {
                try manager.stop(label: Self.label); try awaitIdle()
            }
            let arguments = [cli, "usage", "watch", "--provider", "codex", "--codex-path", codex]
            let plist: [String: Any] = ["Label": Self.label, "ProgramArguments": arguments,
                                        "RunAtLoad": true, "ExitTimeOut": 5,
                                        "KeepAlive": true, "ThrottleInterval": 30,
                                        "AbandonProcessGroup": false]
            try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: plistURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plistURL.path)
            try manager.start(label: Self.label, plist: plistURL)
            return try status()
        }
    }

    public func disable() throws -> UsageServiceStatus {
        try withManagementLock {
            let deadline = now() + 5
            let process = try manager.inspect(label: Self.label, timeout: max(0, deadline - now()))
            // Remove automatic startup before requesting shutdown. bootout removes the
            // job (including KeepAlive), rather than signalling a job launchd will restart.
            if FileManager.default.fileExists(atPath: plistURL.path) {
                try FileManager.default.removeItem(at: plistURL)
            }
            if process.loaded {
                try manager.stop(label: Self.label, timeout: max(0, deadline - now()))
            }
            if process.running {
                try awaitIdle(deadline: deadline)
            }
            return try status(process: .init(loaded: false, running: false), probe: deadline - now() >= 0.3)
        }
    }

    private func awaitIdle(deadline: TimeInterval? = nil) throws {
        let deadline = deadline ?? (now() + 5)
        for _ in 0 ..< 50 {
            if try collectorIdle() {
                return
            }
            guard now() < deadline else { throw UsageServiceError.shutdownPending }
            wait(min(0.1, deadline - now()))
        }
        throw UsageServiceError.shutdownPending
    }

    private func validExecutable(_ path: String) -> Bool {
        var directory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &directory)
            && !directory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }

    private func readConfiguration() throws -> [String]? {
        guard FileManager.default.fileExists(atPath: plistURL.path) else { return nil }
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil)
            as? [String: Any], plist["Label"] as? String == Self.label,
            let arguments = plist["ProgramArguments"] as? [String], arguments.count == 7,
            Array(arguments[1 ... 5]) == ["usage", "watch", "--provider", "codex", "--codex-path"] else {
            throw UsageServiceError.invalidConfiguration
        }
        return arguments
    }

    private func withManagementLock<T>(_ body: () throws -> T) throws -> T {
        let coordination = UsageCoordination(cacheURL: cacheURL, lockName: "account-usage-service.lock")
        defer { coordination.close() }
        guard try coordination.acquire() else { throw UsageServiceError.managementBusy }
        return try body()
    }
}
