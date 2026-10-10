@testable import BuildrHooksCLI
@testable import BuildrHooksCore
import Foundation
import Testing

private final class SimulatedLaunchctl: UsageServiceManaging, @unchecked Sendable {
    var loaded = false
    var running = false
    var starts = 0
    var stops = 0
    var stopFailure = false
    var onInspect: (TimeInterval) -> Void = { _ in }
    var onStop: (TimeInterval) -> Void = { _ in }
    var keepAlive = false
    var throttle: TimeInterval = 0
    var nextRestart: TimeInterval?
    var lastStart: TimeInterval = 0
    func inspect(label _: String) throws -> UsageServiceProcessState {
        .init(loaded: loaded, running: running)
    }

    func start(label _: String, plist: URL) throws {
        let configuration = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)
            as? [String: Any]
        keepAlive = configuration?["KeepAlive"] as? Bool ?? false
        throttle = configuration?["ThrottleInterval"] as? TimeInterval ?? 0
        loaded = true; running = true; starts += 1
    }

    func crash(at time: TimeInterval) {
        running = false
        nextRestart = max(time, lastStart + throttle)
    }

    func advance(to time: TimeInterval) {
        if loaded, keepAlive, !running, let nextRestart, time >= nextRestart {
            running = true; starts += 1
            lastStart = time
            self.nextRestart = nil
        }
    }

    func stop(label _: String) throws {
        if stopFailure {
            throw UsageServiceError.launchctlUnavailable
        }
        loaded = false; running = false; stops += 1
    }

    func inspect(label: String, timeout: TimeInterval) throws -> UsageServiceProcessState {
        onInspect(timeout)
        return try inspect(label: label)
    }

    func stop(label: String, timeout: TimeInterval) throws {
        onStop(timeout)
        try stop(label: label)
    }
}

struct UsageServiceTests {
    @Test func crashLoopBackoffAndDisableNeverResurrectsJob() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var service = fixture.service
        service.collectorAvailable = { fixture.manager.running }
        _ = try service.enable(providers: ["codex"], cliPath: fixture.cli, codexPath: fixture.codex)
        #expect(try service.status().processHealth == .enabled)
        for time in stride(from: 0.0, to: 90, by: 30) {
            fixture.manager.crash(at: time)
            #expect(try service.status().processHealth == .restarting)
            let starts = fixture.manager.starts
            fixture.manager.advance(to: time + 29)
            #expect(fixture.manager.starts == starts)
            fixture.manager.advance(to: time + 30)
            #expect(fixture.manager.starts == starts + 1)
        }
        service.collectorAvailable = { false }
        #expect(try service.status().processHealth == .unavailable)
        fixture.manager.crash(at: 90)
        #expect(try service.disable().processHealth == .stopped)
        let starts = fixture.manager.starts
        fixture.manager.advance(to: 1000)
        #expect(!fixture.manager.running && fixture.manager.starts == starts)
        #expect(!FileManager.default.fileExists(atPath: service.plistURL.path))
    }

    @Test func failedBootoutRemovesStartupButReportsFailureAndLoadedJob() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.service.enable(providers: ["codex"], cliPath: fixture.cli, codexPath: fixture.codex)
        fixture.manager.stopFailure = true
        #expect(throws: UsageServiceError.launchctlUnavailable) { try fixture.service.disable() }
        #expect(!FileManager.default.fileExists(atPath: fixture.service.plistURL.path))
        let status = try fixture.service.status()
        #expect(!status.configured && status.installed && status.processHealth == .unavailable)
        fixture.manager.stopFailure = false
        #expect(try fixture.service.disable().processHealth == .stopped)
    }

    @Test func disableSharesOneDeadlineAcrossInspectionBootoutAndOwnershipWait() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        _ = try fixture.service.enable(providers: ["codex"], cliPath: fixture.cli, codexPath: fixture.codex)
        var time: TimeInterval = 0
        fixture.manager.onInspect = { timeout in #expect(timeout == 5); time += 2 }
        fixture.manager.onStop = { timeout in
            #expect(timeout == 3)
            #expect(!FileManager.default.fileExists(atPath: fixture.service.plistURL.path))
            time += 2
        }
        var service = fixture.service
        service.now = { time }
        service.wait = { time += $0 }
        service.collectorIdle = { false }
        #expect(throws: UsageServiceError.shutdownPending) { try service.disable() }
        #expect(abs(time - 5) < 0.00001)
        #expect(!fixture.manager.loaded && !fixture.manager.running)
    }

    private struct Fixture {
        let root: URL
        let service: UsageService
        let manager: SimulatedLaunchctl
        let cli: String
        let codex: String
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cli = root.appendingPathComponent("stable cli").path
        let codex = root.appendingPathComponent("stable codex").path
        for path in [cli, codex] {
            try Data("#!/bin/false\n".utf8).write(to: URL(fileURLWithPath: path))
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        let manager = SimulatedLaunchctl()
        var service = UsageService(
            home: root, cacheURL: root.appendingPathComponent("cache/state.json"), manager: manager
        )
        service.collectorAvailable = { false }
        service.collectorIdle = { true }
        service.wait = { _ in }
        return Fixture(root: root, service: service, manager: manager, cli: cli, codex: codex)
    }

    @Test func enableIsExplicitDirectAndRepeatableWithStablePaths() throws {
        let fixture = try fixture()
        let root = fixture.root
        let service = fixture.service
        let manager = fixture.manager
        let cli = fixture.cli
        let codex = fixture.codex
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: UsageServiceError.invalidProvider) {
            try service.enable(providers: [], cliPath: cli, codexPath: codex)
        }
        #expect(throws: UsageServiceError.invalidProvider) {
            try service.enable(providers: ["claude"], cliPath: cli, codexPath: codex)
        }
        let first = try service.enable(providers: ["codex", "codex"], cliPath: cli, codexPath: codex)
        #expect(first.enabledProviders == [.codex])
        #expect(first.configured && first.installed && first.processRunning && !first.collectorAvailable)
        _ = try service.enable(providers: ["codex"], cliPath: nil, codexPath: nil,
                               currentExecutable: "/upgrade/missing", searchPath: "/missing")
        #expect(manager.starts == 2 && manager.stops == 1)
        let plist = try #require(PropertyListSerialization.propertyList(
            from: Data(contentsOf: service.plistURL), format: nil
        ) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == [
            cli, "usage", "watch", "--provider", "codex", "--codex-path", codex
        ])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect(plist["KeepAlive"] as? Bool == true)
        #expect(plist["ThrottleInterval"] as? Int == 30)
        #expect(plist["ExitTimeOut"] as? Int == 5)
        #expect(plist["AbandonProcessGroup"] as? Bool == false)
        #expect(plist["Program"] == nil)
    }

    @Test func missingExecutablesDoNotInstallAndOverridesRepairPaths() throws {
        let fixture = try fixture()
        let root = fixture.root
        let service = fixture.service
        let manager = fixture.manager
        let cli = fixture.cli
        let codex = fixture.codex
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: UsageServiceError.cliExecutableUnavailable) {
            try service.enable(providers: ["codex"], cliPath: "relative", codexPath: codex)
        }
        #expect(throws: UsageServiceError.codexExecutableUnavailable) {
            try service.enable(providers: ["codex"], cliPath: cli, codexPath: root.path)
        }
        #expect(manager.starts == 0)
        _ = try service.enable(providers: ["codex"], cliPath: cli, codexPath: codex)
        try FileManager.default.removeItem(atPath: codex)
        #expect(try !service.status().executablesValid)
        _ = try service.enable(providers: ["codex"], cliPath: cli, codexPath: cli)
    }

    @Test func conflictsLeaveConfigurationUntouched() throws {
        let fixture = try fixture()
        let root = fixture.root
        let original = fixture.service
        let manager = fixture.manager
        let cli = fixture.cli
        let codex = fixture.codex
        defer { try? FileManager.default.removeItem(at: root) }
        var service = original
        service.collectorIdle = { false }
        #expect(throws: UsageServiceError.foregroundConflict) {
            try service.enable(providers: ["codex"], cliPath: cli, codexPath: codex)
        }
        #expect(manager.starts == 0 && !FileManager.default.fileExists(atPath: service.plistURL.path))
    }

    @Test func stoppedInstalledServiceDoesNotDisplaceForegroundOwner() throws {
        let fixture = try fixture()
        let root = fixture.root
        let original = fixture.service
        let manager = fixture.manager
        let cli = fixture.cli
        let codex = fixture.codex
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try original.enable(providers: ["codex"], cliPath: cli, codexPath: codex)
        let configuration = try Data(contentsOf: original.plistURL)
        manager.running = false
        var service = original
        service.collectorIdle = { false }
        service.collectorAvailable = { true }
        #expect(throws: UsageServiceError.foregroundConflict) {
            try service.enable(providers: ["codex"], cliPath: nil, codexPath: nil)
        }
        #expect(manager.stops == 0 && manager.starts == 1)
        #expect(try Data(contentsOf: service.plistURL) == configuration)
        let disabled = try service.disable()
        #expect(!disabled.configured && !disabled.installed && disabled.collectorAvailable)
    }

    @Test func disableRetainsCacheAndStatusSeparatesProcessFromConfiguration() throws {
        let fixture = try fixture()
        let root = fixture.root
        let service = fixture.service
        let manager = fixture.manager
        let cli = fixture.cli
        let codex = fixture.codex
        defer { try? FileManager.default.removeItem(at: root) }
        let store = UsageFileStateStore(fileURL: service.cacheURL)
        var durable = UsageDurableState()
        var provider = UsageProviderState()
        provider.revision = 7
        provider.latestInvalidationRevision = 4
        provider.status = .init(provider: .codex, revision: 7, observedAt: 1, status: .ready,
                                latestInvalidationRevision: 4)
        durable.providers["codex"] = provider
        try store.save(durable)
        let before = try Data(contentsOf: service.cacheURL)
        _ = try service.enable(providers: ["codex"], cliPath: cli, codexPath: codex)
        manager.running = false
        let stopped = try service.status()
        #expect(stopped.configured && stopped.installed && !stopped.processRunning && !stopped.collectorAvailable)
        #expect(stopped.retainedCollectionStatus.first?.status == .ready)
        let disabled = try service.disable()
        #expect(!disabled.configured && !disabled.installed && disabled.enabledProviders.isEmpty)
        #expect(try Data(contentsOf: service.cacheURL) == before)
        _ = try service.disable()
        let json = try #require(String(bytes: JSONEncoder().encode(stopped), encoding: .utf8))
        #expect(json.contains("collectorAvailable") && json.contains("retainedCollectionStatus"))
        #expect(!json.contains(cli) && !json.contains(codex) && !json.contains("Fingerprint"))
    }

    @Test func stableSymlinkAndPathSearchArePreservedAndExplicitOverrideReplacesCLI() throws {
        let fixture = try fixture()
        let root = fixture.root
        let service = fixture.service
        let cli = fixture.cli
        let codex = fixture.codex
        defer { try? FileManager.default.removeItem(at: root) }
        let link = root.appendingPathComponent("buildrhooks")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: cli)
        let discovered = root.appendingPathComponent("codex")
        try FileManager.default.createSymbolicLink(atPath: discovered.path, withDestinationPath: codex)
        _ = try service.enable(providers: ["codex"], cliPath: link.path, codexPath: nil, searchPath: root.path)
        let data = try #require(String(bytes: Data(contentsOf: service.plistURL), encoding: .utf8))
        #expect(data.contains(link.path) && data.contains(discovered.path))
        #expect(!data.contains("stable cli") && !data.contains("stable codex"))
        _ = try service.enable(providers: ["codex"], cliPath: cli, codexPath: nil)
        let updated = try #require(String(bytes: Data(contentsOf: service.plistURL), encoding: .utf8))
        #expect(updated.contains(cli))
    }

    @Test func shutdownIsBoundedAndDoesNotRemoveCommittedRecoveryState() throws {
        let fixture = try fixture()
        let root = fixture.root
        let original = fixture.service
        let manager = fixture.manager
        let cli = fixture.cli
        let codex = fixture.codex
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try original.enable(providers: ["codex"], cliPath: cli, codexPath: codex)
        var service = original
        service.collectorIdle = { false }
        #expect(throws: UsageServiceError.shutdownPending) { try service.disable() }
        #expect(!manager.loaded && !FileManager.default.fileExists(atPath: service.plistURL.path))
    }

    @Test func serviceCommandsParseAndHelpDescribeConsent() throws {
        let command = try UsageServiceEnableCommand.parse([
            "--provider", "codex", "--provider", "codex", "--json", "--codex-path", "/codex", "--cli-path", "/cli"
        ])
        #expect(command.provider == ["codex", "codex"] && command.json)
        #expect(command.cliPath == "/cli" && command.codexPath == "/codex")
        #expect(try UsageServiceDisableCommand.parse(["--json"]).json)
        #expect(try UsageServiceStatusCommand.parse(["--json"]).json)
        #expect(UsageServiceEnableCommand.helpMessage().contains("Opt in"))
    }
}

struct UsageServiceCoordinationTests {
    @Test func privatePingDoesNotFetchOrWriteAndDuplicateOwnerIsRejected() throws {
        let cache = URL(fileURLWithPath: "/tmp/s-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: cache.deletingLastPathComponent()) }
        let owner = UsageCoordination(cacheURL: cache)
        defer { owner.close() }
        #expect(try owner.acquire())
        try owner.startServing()
        let provider = CoordinatedProvider()
        let runtime = UsageRuntime(fetcher: provider, store: UsageFileStateStore(fileURL: cache),
                                   notifier: CoordinationNotifier())
        let done = DispatchGroup()
        let capture = CoordinationCapture()
        done.enter()
        DispatchQueue.global().async {
            capture.append(String(UsageCoordination(cacheURL: cache).available(timeout: 1)))
            done.leave()
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        while done.wait(timeout: .now()) != .success, ProcessInfo.processInfo.systemUptime < deadline {
            owner.serve { runtime.dispatch($0) }
            Thread.sleep(forTimeInterval: 0.001)
        }
        #expect(capture.output == ["true"])
        #expect(provider.count == 0 && !FileManager.default.fileExists(atPath: cache.path))
        #expect(try !UsageCoordination(cacheURL: cache).acquire())
    }
}
