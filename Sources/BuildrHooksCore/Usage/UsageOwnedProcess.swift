import Darwin
import Foundation

/// Closures are bound to a child created by this collector, never a discovered PID.
/// The injected clock/process boundary permits testing shutdown without real signals.
struct UsageOwnedProcessShutdown {
    var running: () -> Bool
    var closeInput: () -> Void
    var requestTermination: () -> Void
    var forceTermination: () -> Void
    var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    var wait: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }

    func stop(timeout: TimeInterval = 5) {
        let deadline = now() + min(5, max(0, timeout))
        closeInput()
        guard running() else { return }
        requestTermination()
        while running(), now() < deadline {
            wait(min(0.01, max(0, deadline - now())))
        }
        if running() {
            forceTermination()
        }
    }
}

/// Writes only to the input pipe of a child owned by this collector.
enum UsageOwnedProcessInput {
    static func write(_ data: Data, to handle: FileHandle) throws {
        // Protect only this descriptor: a closed child pipe must return EPIPE, not
        // terminate the host. A process-wide SIGPIPE handler would affect other owners.
        guard fcntl(handle.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw UsageFetchError.temporaryFailure
        }
        do { try handle.write(contentsOf: data) } catch { throw UsageFetchError.temporaryFailure }
    }
}
