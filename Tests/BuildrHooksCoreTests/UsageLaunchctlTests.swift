@testable import BuildrHooksCore
import Foundation
import Testing

struct UsageLaunchctlTests {
    private func executable(_ body: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let url = root.appendingPathComponent("launchctl")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    @Test func processAdapterRecognizesRunningLoadedAndMissingJobs() throws {
        for (body, loaded, running) in [
            ("echo 'state = running'", true, true),
            ("echo 'state = waiting'", true, false),
            ("exit 113", false, false)
        ] {
            let url = try executable(body)
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let state = try UsageLaunchctl(executable: url).inspect(label: "fixture")
            #expect(state.loaded == loaded && state.running == running)
        }
    }

    @Test func bootstrapAndBootoutHonorTheirDifferentSuccessCodes() throws {
        for code in [0, 113, 1] {
            let url = try executable("exit \(code)")
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
            let adapter = UsageLaunchctl(executable: url)
            if code == 0 {
                try adapter.start(label: "fixture", plist: url)
            } else {
                #expect(throws: UsageServiceError.launchctlUnavailable) {
                    try adapter.start(label: "fixture", plist: url)
                }
            }
            if code == 1 {
                #expect(throws: UsageServiceError.launchctlUnavailable) { try adapter.stop(label: "fixture") }
                #expect(throws: UsageServiceError.launchctlUnavailable) { try adapter.inspect(label: "fixture") }
            } else {
                try adapter.stop(label: "fixture")
            }
        }
    }

    @Test func nonexistentExecutableAndExpiredBudgetReportTypedFailures() {
        let adapter = UsageLaunchctl(executable: URL(fileURLWithPath: "/missing/launchctl"))
        #expect(throws: UsageServiceError.launchctlUnavailable) { try adapter.inspect(label: "fixture") }
        #expect(throws: UsageServiceError.shutdownPending) { try adapter.stop(label: "fixture", timeout: 0) }
    }

    @Test func drainsLargeOutputWithoutDeadlockAndTerminatesTimedOutChild() throws {
        let url = try executable("i=0; while [ $i -lt 5000 ]; do echo 'state = running'; i=$((i+1)); done")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(try UsageLaunchctl(executable: url).inspect(label: "fixture").running)
        try Data("#!/bin/sh\nexec /bin/sleep 20\n".utf8).write(to: url)
        let start = ProcessInfo.processInfo.systemUptime
        #expect(throws: UsageServiceError.launchctlUnavailable) {
            try UsageLaunchctl(executable: url).inspect(label: "fixture", timeout: 0.1)
        }
        #expect(ProcessInfo.processInfo.systemUptime - start < 2)
    }
}
