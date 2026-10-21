import ArgumentParser
@testable import BuildrHooksCLI
import BuildrHooksCore
import Foundation
import Testing

struct ClaudeModTests {
    @Test func previewApplyUpgradeRemovePreserveUnrelatedSettings() throws {
        let parent = URL(fileURLWithPath: "/private/tmp/mod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let unrelated = parent.appendingPathComponent("settings.json")
        let settings = Data(#"{"statusLine":{"command":"printf custom"},"enabledPlugins":{"other":true}}"#.utf8)
        try settings.write(to: unrelated)
        let target = parent.appendingPathComponent("plugin")
        let executable = parent.appendingPathComponent("bridge with 'quotes'")
        let setup = ClaudeModSetup(directory: target, assets: ClaudeModCommand.assets, executable: executable)
        #expect(try setup.setup(apply: false).contains("Preview"))
        #expect(!FileManager.default.fileExists(atPath: target.path))
        _ = try setup.setup(apply: true)
        let source = try String(contentsOf: target.appendingPathComponent("hooks/register.js"), encoding: .utf8)
        let encoded = try #require(String(bytes: JSONEncoder().encode(executable.path), encoding: .utf8))
        #expect(source.contains("const executable = " + encoded))
        #expect(!source.contains("'__BUILDRHOOKS_EXECUTABLE__'"))
        _ = try setup.setup(apply: true)
        #expect(try Data(contentsOf: unrelated) == settings)
        _ = try setup.remove(apply: false)
        #expect(FileManager.default.fileExists(atPath: target.path))
        _ = try setup.remove(apply: true)
        #expect(!FileManager.default.fileExists(atPath: target.path))
        #expect(try Data(contentsOf: unrelated) == settings)
    }

    @Test func editedUnknownAndSymlinkedFilesAreNeverOverwrittenOrRemoved() throws {
        let parent = URL(fileURLWithPath: "/private/tmp/mod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("plugin")
        let setup = ClaudeModSetup(directory: target, assets: ClaudeModCommand.assets,
                                   executable: URL(fileURLWithPath: "/unused"))
        _ = try setup.setup(apply: true)
        let unknown = target.appendingPathComponent("unrelated")
        try Data("keep".utf8).write(to: unknown)
        #expect(throws: (any Error).self) { try setup.setup(apply: true) }
        #expect(throws: (any Error).self) { try setup.remove(apply: true) }
        try FileManager.default.removeItem(at: unknown)
        let source = target.appendingPathComponent("hooks/register.js")
        try Data("edited".utf8).write(to: source)
        #expect(throws: (any Error).self) { try setup.setup(apply: true) }
        #expect(throws: (any Error).self) { try setup.remove(apply: true) }
        #expect(try String(contentsOf: source, encoding: .utf8) == "edited")
        let link = parent.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) {
            try ClaudeModSetup(directory: link, assets: ClaudeModCommand.assets,
                               executable: URL(fileURLWithPath: "/unused")).remove(apply: true)
        }
    }

    @Test func modCaptureAndTerminalCaptureShareClearRecoveryAndProviderOwner() throws {
        let root = URL(fileURLWithPath: "/private/tmp/mod-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageFileStateStore(fileURL: root.appendingPathComponent("state.json"))
        let provider = CoordinatedProvider()
        let notifications = CoordinationCapture()
        let runtime = UsageRuntime(fetcher: provider, store: store, notifier: ModUsageNotifier(output: notifications),
                                   cliVersion: "1.2.9", output: { _ in })
        let coordination = UsageCoordination(cacheURL: store.fileURL)
        _ = coordination.refresh(runtime: runtime)
        let codex = try #require(store.load().providers["codex"]?.snapshot)
        for (surface, report) in [("statusline", #"{"rate_limits":{"five_hour":{"used_percentage":11}}}"#),
                                  ("mod", #"{"rate_limits":{"seven_day":{"used_percentage":0}}}"#)] {
            var command = try #require(try BuildrHooksCLICommand.parseAsRoot(
                ["claude", surface, "capture", "--json"]
            ) as? ClaudeStatusLineCaptureCommand)
            command.makeRuntime = { runtime }
            command.makeCoordination = { coordination }
            command.makeSignals = { ClaudeStatusLineSignals(numbers: []) }
            command.readInput = { _ in Data(report.utf8) }
            try command.run()
        }
        let retained = try #require(store.load().providers["claude"]?.snapshot)
        #expect(retained.windows.count == 1 && retained.windows.first?.role == "secondary")
        #expect(retained.windows.first?.usedPercent == 0 && retained.collectedAt == nil)
        runtime.recover(providers: [.claude])
        #expect(try store.load().providers["claude"]?.snapshot == retained)
        #expect(try store.load().providers["codex"]?.snapshot == codex && provider.count == 1)
        let snapshots = notifications.output.compactMap { try? UsageWire().decodeSnapshot($0, now: Date()) }
            .filter { $0.provider == .claude }
        let published = try #require(snapshots.last)
        #expect(published.windows == retained.windows && published.receivedAt == retained.receivedAt)
        #expect(published.revision == retained.revision && published.schemaVersion == 2)
    }

    @Test func distinctModCapabilityIsAbsentInOlderCapabilityPayloads() throws {
        let encoded = try JSONEncoder().encode(BuildrHooksCapabilities.current)
        var object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["claudeModUsageCapture"] as? Bool == true)
        object.removeValue(forKey: "claudeModUsageCapture")
        let old = try JSONDecoder().decode(BuildrHooksCapabilities.self,
                                           from: JSONSerialization.data(withJSONObject: object))
        #expect(!old.claudeModUsageCapture)
    }
}

private struct ModUsageNotifier: UsageNotifying {
    let output: CoordinationCapture
    func post(name _: String, payload: String) {
        output.append(payload)
    }
}
