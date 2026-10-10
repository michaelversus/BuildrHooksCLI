import Darwin
import Foundation

public struct CodexUsageFetcher: UsageFetching {
    public let executablePath: String?
    public init(executablePath: String? = nil) {
        self.executablePath = executablePath
    }

    public func fetch(timeout: TimeInterval) throws -> Data {
        let executable = try resolveExecutable()
        let session = CodexUsageSession(executable: executable, timeout: min(30, max(0, timeout)))
        return try session.fetch()
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
    private let deadline: TimeInterval
    private var buffer = Data()
    private var receivedBytes = 0
    init(executable: URL, timeout: TimeInterval) {
        deadline = ProcessInfo.processInfo.systemUptime + timeout
        process.executableURL = executable
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = input
        process.standardOutput = output
        // Never inherit provider diagnostics: they can contain identity, paths, or credentials.
        process.standardError = FileHandle.nullDevice
    }

    func fetch() throws -> Data {
        do { try process.run() } catch { throw UsageFetchError.executableUnavailable }
        defer { shutdown() }
        _ = try request(id: 1, method: "initialize", params: [
            "clientInfo": ["name": "buildrhooks", "title": "BuildrHooksCLI", "version": "1"]
        ])
        try send(["method": "initialized"])
        let account = try request(id: 2, method: "account/read", params: ["refreshToken": false])
        // Null identity is supported. No login or credential-file extraction is attempted.
        if (account["requiresOpenaiAuth"] as? Bool) == true,
           account["account"] == nil || account["account"] is NSNull {
            throw UsageFetchError.authenticationRequired
        }
        let limits = try request(id: 3, method: "account/rateLimits/read", params: NSNull())
        return try JSONSerialization.data(withJSONObject: limits)
    }

    private func send(_ message: [String: Any]) throws {
        guard ProcessInfo.processInfo.systemUptime < deadline else { throw UsageFetchError.timeout }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        do { try input.fileHandleForWriting.write(contentsOf: data) } catch { throw UsageFetchError.temporaryFailure }
    }

    private func request(id: Int, method: String, params: Any) throws -> [String: Any] {
        try send(["id": id, "method": method, "params": params])
        while true {
            let line = try readLine()
            guard let message = try JSONSerialization.jsonObject(with: line) as? [String: Any] else {
                throw UsageFetchError.temporaryFailure
            }
            guard (message["id"] as? Int) == id else { continue }
            if let error = message["error"] as? [String: Any] {
                throw classify(error)
            }
            guard let result = message["result"] as? [String: Any] else {
                throw UsageFetchError.temporaryFailure
            }
            return result
        }
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

    private func shutdown() {
        try? input.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let stopDeadline = ProcessInfo.processInfo.systemUptime + 0.2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < stopDeadline {
                usleep(10000)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        try? output.fileHandleForReading.close()
    }
}
