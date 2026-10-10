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
