import Foundation
import Testing

/// Contract fixture for the app-owned best-effort hook; this does not install a Git hook.
struct TrackingRewriteHookTests {
    @Test(arguments: [0, 33, 127])
    func optionalRecordingNeverChangesSuccessfulHookExit(recordingExit: Int) throws {
        let fixture = try TrackingFixture()
        defer { fixture.close() }
        let stub = fixture.root.appending(path: "recording-stub")
        let wrapper = fixture.root.appending(path: "post-rewrite-contract")
        let capture = fixture.root.appending(path: "arguments")
        try Data("""
        #!/bin/sh
        printf '%s\\n' "$@" > "$CAPTURE"
        exit "$RECORDING_EXIT"
        """.utf8).write(to: stub)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stub.path)
        try Data("""
        #!/bin/sh
        if ! "$1" tracking record-rewrite --scope "$2" --execution "$3"; then
          printf '%s\\n' 'BuildrAI rewrite recording failed; retain input and retry.' >&2
        fi
        exit 0
        """.utf8).write(to: wrapper)
        let syntax = Process()
        syntax.executableURL = URL(fileURLWithPath: "/bin/sh")
        syntax.arguments = ["-n", wrapper.path]
        try syntax.run()
        syntax.waitUntilExit()
        #expect(syntax.terminationStatus == 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let executable = recordingExit == 127 ? fixture.root.appending(path: "unavailable").path : stub.path
        process.arguments = [wrapper.path, executable, "/authorized scope.json", "/retained rewrite.json"]
        process.environment = ["CAPTURE": capture.path, "RECORDING_EXIT": String(recordingExit)]
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let diagnostic = try #require(String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8))
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(diagnostic.contains("retain input and retry") == (recordingExit != 0))
        if recordingExit != 127 {
            let arguments = try String(contentsOf: capture, encoding: .utf8).split(separator: "\n").map(String.init)
            #expect(arguments == ["tracking", "record-rewrite", "--scope", "/authorized scope.json",
                                  "--execution", "/retained rewrite.json"])
        }
    }
}
