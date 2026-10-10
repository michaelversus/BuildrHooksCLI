import Darwin
import Foundation

public final class CodexUsageFetcher: UsageFetching, @unchecked Sendable {
    private var session: CodexUsageSession?
    private var watching = false
    public let executablePath: String?
    public init(executablePath: String? = nil) {
        self.executablePath = executablePath
    }

    public func beginWatch() {
        watching = true
    }

    public func close() {
        session?.shutdown(); session = nil
    }

    public func events() throws -> [UsageWatchTrigger] {
        try session?.events() ?? []
    }

    public func currentAccountIdentity(timeout: TimeInterval) throws -> String? {
        try currentAccountIdentity(timeout: timeout, isCancelled: { false })
    }

    public func currentAccountIdentity(
        timeout: TimeInterval, isCancelled: @escaping @Sendable () -> Bool
    ) throws -> String? {
        guard !isCancelled() else { throw UsageFetchError.cancelled }
        if session == nil {
            session = try CodexUsageSession(executable: resolveExecutable())
        }
        defer {
            if !watching {
                close()
            }
        }
        do {
            return try session?.currentAccountIdentity(timeout: timeout, isCancelled: isCancelled)
        } catch {
            close()
            throw error
        }
    }

    public func fetch(timeout: TimeInterval) throws -> Data {
        try fetch(timeout: timeout, isCancelled: { false })
    }

    public func fetch(timeout: TimeInterval, isCancelled: @escaping @Sendable () -> Bool) throws -> Data {
        if session == nil {
            session = try CodexUsageSession(executable: resolveExecutable())
        }
        defer {
            if !watching {
                close()
            }
        }
        do {
            guard let session else { throw UsageFetchError.temporaryFailure }
            return try session.fetch(timeout: min(30, max(0, timeout)), isCancelled: isCancelled)
        } catch {
            if let failure = error as? UsageFetchError {
                switch failure {
                case .authenticationRequired, .unavailable, .throttled: break
                default: close()
                }
            } else {
                close()
            }
            throw error
        }
    }

    private func resolveExecutable() throws -> URL {
        let candidates: [String]
        if let executablePath {
            guard executablePath.hasPrefix("/") else { throw UsageFetchError.executableUnavailable }
            candidates = [executablePath]
        } else {
            candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":").filter { $0.hasPrefix("/") }.map { "\($0)/codex" }
        }
        for path in candidates {
            var directory: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue,
               FileManager.default.isExecutableFile(atPath: path) {
                return URL(fileURLWithPath: path)
            }
        }
        throw UsageFetchError.executableUnavailable
    }
}

private final class CodexUsageSession {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var deadline: TimeInterval = 0
    private var isCancelled: @Sendable () -> Bool = { false }
    private var initialized = false
    private var requestID = 0
    private var pendingEvents: [UsageWatchTrigger] = []
    private var buffer = Data()
    private var receivedBytes = 0
    init(executable: URL) {
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        // Never inherit provider diagnostics: they can contain identity, paths, or credentials.
        process.standardError = FileHandle.nullDevice
    }

    func fetch(timeout: TimeInterval, isCancelled: @escaping @Sendable () -> Bool) throws -> Data {
        self.isCancelled = isCancelled
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        receivedBytes = 0
        try initialize()
        let account = try readAccount()
        // Null identity is supported. No login or credential-file extraction is attempted.
        if (account["requiresOpenaiAuth"] as? Bool) == true,
           account["account"] == nil || account["account"] is NSNull {
            throw UsageFetchError.authenticationRequired
        }
        let limits = try request(method: "account/rateLimits/read", params: NSNull())
        return try JSONSerialization.data(withJSONObject: limits)
    }

    private func initialize() throws {
        if !initialized {
            do { try process.run() } catch { throw UsageFetchError.executableUnavailable }
            _ = try request(method: "initialize", params: [
                "clientInfo": ["name": "buildrhooks", "title": "BuildrHooksCLI", "version": "1"]
            ])
            try send(["method": "initialized"])
            initialized = true
        }
    }

    private func readAccount() throws -> [String: Any] {
        try request(method: "account/read", params: ["refreshToken": false])
    }

    func currentAccountIdentity(timeout: TimeInterval, isCancelled: @escaping @Sendable () -> Bool) throws -> String? {
        deadline = ProcessInfo.processInfo.systemUptime + min(5, max(0, timeout))
        self.isCancelled = isCancelled
        receivedBytes = 0
        try initialize()
        let response = try readAccount()
        // Optional routing identity only. Email, plan, and authentication mode are not continuity proof.
        guard let routing = response["workspaceRouting"] as? [String: Any],
              let identity = routing["chatgptAccountId"] as? String, !identity.isEmpty else { return nil }
        return identity
    }

    private func send(_ message: [String: Any]) throws {
        guard !isCancelled() else { throw UsageFetchError.cancelled }
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw UsageFetchError.timeout }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw UsageFetchError.temporaryFailure }
    }

    private func request(method: String, params: Any) throws -> [String: Any] {
        requestID += 1
        let id = requestID
        try send(["id": id, "method": method, "params": params])
        while true {
            let line = try readLine()
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw UsageFetchError.temporaryFailure
            }
            guard (message["id"] as? Int) == id else {
                recordEvent(message)
                continue
            }
            if let error = message["error"] as? [String: Any] {
                throw classify(error)
            }
            guard let result = message["result"] as? [String: Any] else {
                throw UsageFetchError.temporaryFailure
            }
            return result
        }
    }

    private func recordEvent(_ message: [String: Any]) {
        switch message["method"] as? String {
        case "account/updated", "account/login/completed":
            if !pendingEvents.contains(.authenticationChanged) {
                pendingEvents.append(.authenticationChanged)
            }
        case "account/rateLimits/updated":
            if !pendingEvents.contains(.limitsChanged) {
                pendingEvents.append(.limitsChanged)
            }
        default: break
        }
    }

    func events() throws -> [UsageWatchTrigger] {
        guard initialized else { return [] }
        receivedBytes = 0
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                    throw UsageFetchError.temporaryFailure
                }
                recordEvent(message)
                continue
            }
            guard buffer.count <= 1024 * 1024, receivedBytes <= 4 * 1024 * 1024 else {
                throw UsageFetchError.temporaryFailure
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let ready = poll(&descriptor, 1, 0)
            if ready == 0 {
                break
            }
            guard ready > 0 else { throw UsageFetchError.temporaryFailure }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageFetchError.temporaryFailure }
            receivedBytes += count
            buffer.append(contentsOf: bytes.prefix(count))
        }
        let events = pendingEvents
        pendingEvents.removeAll()
        return events
    }

    private func classify(_ error: [String: Any]) -> UsageFetchError {
        // Raw messages are inspected only in memory, never encoded, stored, or logged.
        let code = error["code"] as? Int
        let message = (error["message"] as? String ?? "").lowercased()
        if code == 401 || code == 403 || message.contains("unauthorized")
            || message.contains("not authenticated") || message.contains("authentication required")
            || message.contains("not logged in") {
            return .authenticationRequired
        }
        if message.contains("requires chatgpt authentication") {
            return .authenticationRequired
        }
        if message.contains("not supported for api") || message.contains("only available for chatgpt") {
            return .unavailable
        }
        if code == 429 || message.contains("too many requests") || message.contains("throttl") {
            let metadata = error["data"] as? [String: Any]
            let seconds = metadata?["retryAfterSeconds"] as? Double
            let retry: Int64? = if let seconds, seconds.isFinite, seconds >= 0, seconds < 1_000_000_000 {
                Int64((Date().timeIntervalSince1970 + seconds) * 1000)
            } else {
                nil
            }
            return .throttled(retryAt: retry)
        }
        return .temporaryFailure
    }

    private func readLine() throws -> Data {
        while true {
            guard !isCancelled() else { throw UsageFetchError.cancelled }
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw UsageFetchError.timeout }
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                return line
            }
            guard buffer.count <= 1024 * 1024, receivedBytes <= 4 * 1024 * 1024 else {
                throw UsageFetchError.temporaryFailure
            }
            var descriptor = pollfd(fd: output.fileHandleForReading.fileDescriptor, events: Int16(POLLIN), revents: 0)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            let ready = poll(&descriptor, 1, Int32(min(100, max(1, remaining * 1000))))
            if ready == 0 {
                continue
            }
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                throw UsageFetchError.temporaryFailure
            }
            var bytes = [UInt8](repeating: 0, count: 8192)
            let count = Darwin.read(descriptor.fd, &bytes, bytes.count)
            guard count > 0 else { throw UsageFetchError.temporaryFailure }
            receivedBytes += count
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }

    func shutdown() {
        // Leave one second inside launchd's five-second parent deadline for direct
        // child cleanup. Foundation children need not share the launchd job's group.
        UsageOwnedProcessShutdown(
            running: { self.process.isRunning },
            closeInput: { try? self.input.fileHandleForWriting.close() },
            requestTermination: { self.process.terminate() },
            forceTermination: { kill(self.process.processIdentifier, SIGKILL) }
        ).stop(timeout: 4)
        try? output.fileHandleForReading.close()
    }
}
