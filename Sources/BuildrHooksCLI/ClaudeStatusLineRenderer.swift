import BuildrHooksCore
import Darwin
import Foundation
import Synchronization

private final class ClaudeStatusLineSignalState: Sendable {
    let value = Mutex<Int32?>(nil)
}

final class ClaudeStatusLineSignals: Sendable {
    private let state = ClaudeStatusLineSignalState()
    private let sources: [DispatchSourceSignal]
    private let numbers: [Int32]
    var received: Int32? {
        state.value.withLock { $0 }
    }

    init(numbers: [Int32] = [SIGINT, SIGTERM]) {
        self.numbers = numbers
        let state = state
        sources = numbers.map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { state.value.withLock { $0 = number } }
            source.resume()
            return source
        }
    }

    func close() {
        sources.forEach { $0.cancel() }
        numbers.forEach { signal($0, SIG_DFL) }
    }
}

struct ClaudeStatusLineRenderResult {
    var input: Data?
    var exitCode: Int32 = 0
    var terminationSignal: Int32?
}

/// Dedicated status-line byte bridge. Output/error descriptors pass directly to the delegate.
struct ClaudeStatusLineRenderer {
    var input: FileHandle = .standardInput
    var output: FileHandle = .standardOutput
    var error: FileHandle = .standardError
    var cancelled: () -> Int32? = { nil }

    func render(command: String?) throws -> ClaudeStatusLineRenderResult {
        guard let command else {
            let data = try readCallback()
            if cancelled() == nil {
                try output.write(contentsOf: Data(Self.defaultLine(data).utf8))
            }
            return ClaudeStatusLineRenderResult(input: data, terminationSignal: cancelled())
        }
        let pipe = Pipe()
        let child = try launch(command, pipe: pipe)
        try? pipe.fileHandleForReading.close()
        defer { try? pipe.fileHandleForWriting.close() }
        var completed: Int32?
        let data: Data?
        do {
            data = try stream(to: pipe.fileHandleForWriting, process: child, completed: &completed)
        } catch {
            kill(-child, SIGKILL)
            if completed == nil {
                var status: Int32 = 0; _ = waitpid(child, &status, 0)
            }
            throw error
        }
        try? pipe.fileHandleForWriting.close()
        let status = completed.map(termination) ?? wait(child)
        return ClaudeStatusLineRenderResult(input: data, exitCode: status.exitCode,
                                            terminationSignal: status.terminationSignal)
    }

    func readCallback() throws -> Data? {
        var data = Data()
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while cancelled() == nil, ProcessInfo.processInfo.systemUptime < deadline {
            var event = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 10) > 0 else { continue }
            let chunk = try input.read(upToCount: 65536) ?? Data()
            if chunk.isEmpty {
                return data
            }
            guard data.count + chunk.count <= ClaudeUsageParser.maximumBytes else { return nil }
            data.append(chunk)
        }
        return nil
    }

    private func stream(to destination: FileHandle, process: pid_t, completed: inout Int32?) throws -> Data? {
        var captured: Data? = Data()
        guard fcntl(destination.fileDescriptor, F_SETNOSIGPIPE, 1) == 0,
              fcntl(destination.fileDescriptor, F_SETFL, O_NONBLOCK) == 0 else {
            throw ClaudeStatusLineError.unsafePath
        }
        while cancelled() == nil {
            var status: Int32 = 0
            if waitpid(process, &status, WNOHANG) == process {
                completed = status; return nil
            }
            var event = pollfd(fd: input.fileDescriptor, events: Int16(POLLIN), revents: 0)
            guard poll(&event, 1, 10) > 0 else { continue }
            let chunk = try input.read(upToCount: 65536) ?? Data()
            if chunk.isEmpty {
                return captured
            }
            if let count = captured?.count, count + chunk.count <= ClaudeUsageParser.maximumBytes {
                captured?.append(chunk)
            } else {
                captured = nil
            }
            if !write(chunk, descriptor: destination.fileDescriptor) {
                return nil
            }
        }
        return nil
    }

    private func write(_ data: Data, descriptor: Int32) -> Bool {
        var offset = 0
        while offset < data.count, cancelled() == nil {
            let count = data.withUnsafeBytes { bytes in
                Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), data.count - offset)
            }
            if count > 0 {
                offset += count
            } else if count < 0, errno == EAGAIN || errno == EINTR {
                var event = pollfd(fd: descriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&event, 1, 10)
            } else {
                return false
            }
        }
        return offset == data.count
    }
}

extension ClaudeStatusLineRenderer {
    private func launch(_ command: String, pipe: Pipe) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawnattr_init(&attributes)
        defer { posix_spawn_file_actions_destroy(&actions); posix_spawnattr_destroy(&attributes) }
        posix_spawn_file_actions_adddup2(&actions, pipe.fileHandleForReading.fileDescriptor, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, output.fileDescriptor, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, error.fileDescriptor, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForWriting.fileDescriptor)
        posix_spawn_file_actions_addclose(&actions, pipe.fileHandleForReading.fileDescriptor)
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGINT)
        sigaddset(&defaults, SIGTERM)
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF))
        let commandArguments: [String] = ["sh", "-c", command]
        let strings = commandArguments.map { argument in
            argument.withCString { strdup($0) }
        }
        defer { strings.forEach { free($0) } }
        var arguments = strings + [nil]
        var process: pid_t = 0
        let result = arguments.withUnsafeMutableBufferPointer {
            posix_spawn(&process, "/bin/sh", &actions, &attributes, $0.baseAddress!, environ)
        }
        guard result == 0 else { throw ClaudeStatusLineError.unsafePath }
        return process
    }

    private func wait(_ process: pid_t) -> ClaudeStatusLineRenderResult {
        var status: Int32 = 0
        var deadline: TimeInterval?
        while waitpid(process, &status, WNOHANG) == 0 {
            if let received = cancelled() {
                if deadline == nil {
                    kill(-process, received)
                    deadline = ProcessInfo.processInfo.systemUptime + 0.2
                } else if ProcessInfo.processInfo.systemUptime >= deadline! {
                    kill(-process, SIGKILL)
                }
            }
            Thread.sleep(forTimeInterval: 0.005)
        }
        return termination(status)
    }

    private func termination(_ status: Int32) -> ClaudeStatusLineRenderResult {
        let termination = status & 0x7F
        return ClaudeStatusLineRenderResult(input: nil, exitCode: (status >> 8) & 0xFF,
                                            terminationSignal: cancelled() ??
                                                (termination == 0 ? nil : termination))
    }

    static func defaultLine(_ data: Data?) -> String {
        let windows = data.flatMap { try? ClaudeUsageParser().windows(from: $0) } ?? []
        func remaining(_ role: String) -> String {
            guard let window = windows.first(where: { $0.role == role }) else { return "unavailable" }
            return (100 - window.usedPercent)
                .formatted(.number.locale(Locale(identifier: "en_US_POSIX"))
                    .precision(.fractionLength(0 ... 6))) + "% remaining"
        }
        return "Claude 5h: \(remaining("primary")) | weekly: \(remaining("secondary"))"
    }
}
