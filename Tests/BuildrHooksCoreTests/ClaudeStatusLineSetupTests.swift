@testable import BuildrHooksCLI
import Foundation
import Testing

struct ClaudeStatusLineSetupTests {
    @Test func previewHasNoEffectsAndScopesHonorExplicitSelection() throws {
        let fixture = try StatusLineFixture()
        defer { fixture.close() }
        let settings = fixture.settings
        let text = try settings.setup(apply: false, repair: false, executable: fixture.executable)
        #expect(text.contains("Synthetic preview") && text.contains("footer keyboard hints"))
        #expect(text.contains("account attribution unavailable") && text.contains("no response"))
        #expect(!FileManager.default.fileExists(atPath: settings.directory.path))
        #expect(!FileManager.default.fileExists(atPath: settings.settingsURL.path))
        let home = URL(fileURLWithPath: "/synthetic/home")
        #expect(ClaudeStatusLineSettings.selectedRoot(
            configDirectory: nil,
            project: nil,
            environment: ["CLAUDE_CONFIG_DIR": "/synthetic/custom"],
            home: home
        ).path == "/synthetic/custom")
        #expect(ClaudeStatusLineSettings.selectedRoot(
            configDirectory: "/explicit",
            project: nil,
            environment: ["CLAUDE_CONFIG_DIR": "/ignored"],
            home: home
        ).path == "/explicit")
        let project = ClaudeStatusLineSettings(root: fixture.root, project: true)
        #expect(project.settingsURL.lastPathComponent == "settings.local.json")
    }

    @Test func customValueOptionsAndUnrelatedLaterEditsSurviveRemoval() throws {
        let fixture = try StatusLineFixture()
        defer { fixture.close() }
        let original: [String: Any] = ["type": "command", "command": "printf '%s' 'quote '\"'\"' spaces'",
                                       "padding": 3, "unknown": ["nested": [1, 2]], "refreshInterval": 9]
        try fixture.write(["statusLine": original, "theme": "dark"])
        let settings = fixture.settings
        let text = try settings.setup(apply: true, repair: false, executable: fixture.executable)
        #expect(text.contains("No BuildrAI text will be appended"))
        let saved = try #require(try settings.ownership())
        #expect(try saved.original == (ClaudeStatusLineSettings.value(original)))
        var object = try settings.read().object
        let installed = try #require(object["statusLine"] as? [String: Any])
        #expect(installed["padding"] as? Int == 3 && installed["refreshInterval"] as? Int == 9)
        #expect(try ClaudeStatusLineSettings.value(installed["unknown"]) == ClaudeStatusLineSettings
            .value(original["unknown"]))
        object["theme"] = "light"
        try fixture.write(object)
        _ = try settings.remove(apply: true)
        let restored = try settings.read().object
        #expect(try ClaudeStatusLineSettings.value(restored["statusLine"]) == saved.original)
        #expect(restored["theme"] as? String == "light")
        #expect(try settings.remove(apply: true).contains("already restored"))
    }

    @Test func originalAbsenceAndNullRestoreExactly() throws {
        for original in [nil, NSNull()] as [Any?] {
            let fixture = try StatusLineFixture()
            defer { fixture.close() }
            var object: [String: Any] = ["theme": "dark"]
            object["statusLine"] = original
            try fixture.write(object)
            _ = try fixture.settings.setup(apply: true, repair: false, executable: fixture.executable)
            _ = try fixture.settings.remove(apply: true)
            #expect(try ClaudeStatusLineSettings.value(fixture.settings.read().object["statusLine"])
                == ClaudeStatusLineSettings.value(original))
        }
    }

    @Test func idempotentSetupCopiesSymlinkTargetAndRefreshesRunnerExplicitly() throws {
        let fixture = try StatusLineFixture()
        defer { fixture.close() }
        let symlink = fixture.root.appendingPathComponent("linked buildrhooks")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: fixture.executable)
        _ = try fixture.settings.setup(apply: true, repair: false, executable: symlink)
        let record = try #require(try fixture.settings.ownership())
        let installed = try Data(contentsOf: fixture.settings.settingsURL)
        let runner = URL(fileURLWithPath: record.runnerPath)
        try FileManager.default.removeItem(at: fixture.executable)
        #expect(try Data(contentsOf: runner) == Data("standalone-one".utf8))
        try Data("standalone-two".utf8).write(to: fixture.executable)
        _ = try fixture.settings.setup(apply: true, repair: false, executable: symlink)
        #expect(try Data(contentsOf: runner) == Data("standalone-two".utf8))
        #expect(try Data(contentsOf: fixture.settings.settingsURL) == installed)
        #expect(try FileManager.default
            .attributesOfItem(atPath: runner.path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func externalReplacementRequiresExplicitRepairAndConcurrentEditPreservesOldDelegate() throws {
        let fixture = try StatusLineFixture()
        defer { fixture.close() }
        try fixture.write(["statusLine": ["type": "command", "command": "printf old"]])
        _ = try fixture.settings.setup(apply: true, repair: false, executable: fixture.executable)
        let old = try #require(try fixture.settings.ownership())
        let immutable = URL(fileURLWithPath: old.runnerPath).deletingLastPathComponent()
            .appendingPathComponent("ownership.json")
        let oldBytes = try Data(contentsOf: immutable)
        try fixture.write(["statusLine": ["type": "command", "command": "printf replacement"]])
        #expect(throws: ClaudeStatusLineError.detached) { try fixture.settings.remove(apply: true) }
        #expect(throws: ClaudeStatusLineError.detached) {
            try fixture.settings.setup(apply: true, repair: false, executable: fixture.executable)
        }
        _ = try fixture.settings.setup(apply: false, repair: true, executable: fixture.executable)
        var settings = fixture.settings
        settings.beforeWrite = { try fixture.write(["statusLine": [
            "type": "command",
            "command": "printf newest"
        ]]) }
        #expect(throws: ClaudeStatusLineError.concurrentEdit) {
            try settings.setup(apply: true, repair: true, executable: fixture.executable)
        }
        #expect(try Data(contentsOf: immutable) == oldBytes)
        #expect(try ClaudeStatusLineSettings
            .command(ClaudeStatusLineSettings.value(settings.read().object["statusLine"]))
            == "printf newest")
    }

    @Test func editedManagedWrapperCannotBeWrappedAgainEvenDuringExplicitRepair() throws {
        let fixture = try StatusLineFixture()
        defer { fixture.close() }
        _ = try fixture.settings.setup(apply: true, repair: false, executable: fixture.executable)
        var object = try fixture.settings.read().object
        var line = try #require(object["statusLine"] as? [String: Any])
        line["padding"] = 5
        let installedCommand = try #require(line["command"] as? String)
        for prefix in ["", "  ", "exec "] {
            line["command"] = prefix + installedCommand
            object["statusLine"] = line
            try fixture.write(object)
            let bytes = try Data(contentsOf: fixture.settings.settingsURL)
            #expect(throws: ClaudeStatusLineError.alreadyWrapped) {
                try fixture.settings.setup(apply: true, repair: true, executable: fixture.executable)
            }
            #expect(try Data(contentsOf: fixture.settings.settingsURL) == bytes)
        }
        try fixture.write(["statusLine": ["type": "command",
                                          "command": "printf '%s' ' claude statusline run --metadata harmless'"]])
        let preview = try fixture.settings.setup(apply: false, repair: true, executable: fixture.executable)
        #expect(preview.contains("Delegate exactly: printf"))
    }

    @Test func managedRestrictionsAndUnsafeSettingsNeverChangeConfiguration() throws {
        let fixture = try StatusLineFixture()
        defer { fixture.close() }
        let managed = fixture.root.appendingPathComponent("managed.json")
        try Data(#"{"statusLine":{"type":"command","command":"managed"}}"#.utf8).write(to: managed)
        let settings = ClaudeStatusLineSettings(root: fixture.root, managedURLs: [managed])
        #expect(throws: ClaudeStatusLineError.managed) {
            try settings.setup(apply: true, repair: false, executable: fixture.executable)
        }
        #expect(!FileManager.default.fileExists(atPath: settings.settingsURL.path))
        try FileManager.default.createSymbolicLink(at: settings.settingsURL, withDestinationURL: managed)
        #expect(throws: ClaudeStatusLineError.unsafePath) { try fixture.settings.read() }
    }
}

struct StatusLineFixture {
    let root: URL
    let executable: URL
    var settings: ClaudeStatusLineSettings {
        ClaudeStatusLineSettings(root: root)
    }

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("line ' scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        executable = root.appendingPathComponent("source buildrhooks")
        try Data("standalone-one".utf8).write(to: executable)
    }

    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
            .write(to: settings.settingsURL)
    }

    func close() {
        try? FileManager.default.removeItem(at: root)
    }
}
