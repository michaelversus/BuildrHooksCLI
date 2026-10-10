@testable import BuildrHooksCore
import Foundation
import Testing

private struct FailureCase {
    let error: UsageFetchError
    let outcome: UsageOutcome
    let status: UsageStatusCode

    init(_ error: UsageFetchError, _ outcome: UsageOutcome, _ status: UsageStatusCode) {
        self.error = error
        self.outcome = outcome
        self.status = status
    }
}

private final class UsageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [(String, String)] = []
    func append(_ name: String, _ payload: String) {
        lock.withLock { messages.append((name, payload)) }
    }

    var values: [(String, String)] {
        lock.withLock { messages }
    }
}

private struct FakeUsageFetcher: UsageFetching {
    var response: Data = .init()
    var error: UsageFetchError?
    func fetch(timeout: TimeInterval) throws -> Data {
        #expect(timeout == 30)
        if let error {
            throw error
        }
        return response
    }
}

private struct RecordingUsageNotifier: UsageNotifying {
    let recorder: UsageRecorder
    var fail = false
    func post(name: String, payload: String) throws {
        recorder.append(name, payload)
        if fail {
            throw UsageFetchError.temporaryFailure
        }
    }
}

private struct FailingUsageStore: UsageStateStoring {
    var failLoad = false
    func load() throws -> UsageDurableState {
        if failLoad {
            throw UsageWireError.invalidPayload
        }
        return .init()
    }

    func save(_: UsageDurableState) throws {
        throw UsageWireError.invalidPayload
    }
}

private final class FinalSaveFailingStore: UsageStateStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var saved: UsageDurableState = .init()
    private var saveCount = 0
    func load() throws -> UsageDurableState {
        lock.withLock { saved }
    }

    func save(_ state: UsageDurableState) throws {
        try lock.withLock {
            saveCount += 1
            if saveCount == 2 {
                throw UsageWireError.invalidPayload
            }
            saved = state
        }
    }
}

struct UsageRuntimeTests {
    private let date = Date(timeIntervalSince1970: 1_000_000)
    private var response: Data {
        Data("""
        {"accountId":"secret-account", "email":"secret@example.com",
         "rateLimits":{"primary":{"usedPercent":99}},
         "rateLimitsByLimitId":{
           "codex":{"limitName":"Private label", "primary":{"usedPercent":125,"windowDurationMins":17,
             "resetsAt":2000000}, "secondary":{"usedPercent":3}},
           "review":{"primary":{"usedPercent":0,"windowDurationMins":45}},
           "empty":{"credits":{"balance":"secret-credit"}}}}
        """.utf8)
    }

    private func temporaryStore() throws -> UsageFileStateStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return UsageFileStateStore(fileURL: directory.appendingPathComponent("state.json"))
    }

    @Test func freshObservationNormalizesAllBucketsAndExcludesPrivateFields() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let recorder = UsageRecorder()
        let output = UsageRecorder()
        let runtime = UsageRuntime(fetcher: FakeUsageFetcher(response: response), store: store,
                                   notifier: RecordingUsageNotifier(recorder: recorder), now: { date },
                                   output: { output.append("output", $0) })
        let result = runtime.refresh(json: true)
        #expect(result.outcome == .refreshed)
        #expect(result.publicationAttempted && result.freshSnapshot)
        let snapshot = try #require(store.load().providers["codex"]?.snapshot)
        #expect(snapshot.windows.count == 3)
        #expect(snapshot.windows[0].usedPercent == 125)
        #expect(snapshot.windows[0].durationMinutes == 17)
        #expect(snapshot.windows[0].resetsAt == 2_000_000_000)
        #expect(snapshot.windows[1].durationMinutes == nil)
        #expect(snapshot.windows[1].resetsAt == nil)
        #expect(snapshot.windows.allSatisfy { $0.usedPercent != 99 })
        let persisted = try String(contentsOf: store.fileURL, encoding: .utf8)
        let all = persisted + recorder.values.map(\.1).joined() + output.values.map(\.1).joined()
        for forbidden in ["secret", "email", "accountId", "limitName", "credits", store.fileURL.path] {
            #expect(!all.contains(forbidden))
        }
        #expect(recorder.values.map(\.0) == [
            UsageRuntime.statusNotification, UsageRuntime.snapshotNotification, UsageRuntime.statusNotification
        ])
        let attributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
        let permissions = attributes[.posixPermissions] as? Int
        #expect(permissions == 0o600)
    }

    @Test func allProviderFailuresAreDistinctAndNeverRefreshThePreviousSnapshot() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let recorder = UsageRecorder()
        let notifier = RecordingUsageNotifier(recorder: recorder)
        let success = UsageRuntime(fetcher: FakeUsageFetcher(response: response), store: store,
                                   notifier: notifier, now: { date }, output: { _ in })
        #expect(success.refresh().outcome == .refreshed)
        let original = try #require(store.load().providers["codex"]?.snapshot)
        let failures: [FailureCase] = [
            .init(.authenticationRequired, .authenticationRequired, .authenticationRequired),
            .init(.temporaryFailure, .temporaryFailure, .temporaryFailure),
            .init(.timeout, .timeout, .temporaryFailure),
            .init(.unavailable, .usageUnavailable, .usageUnavailable),
            .init(.executableUnavailable, .executableUnavailable, .temporaryFailure),
            .init(.throttled(retryAt: 9_000_000_000), .throttled, .throttled)
        ]
        var exits = Set<Int32>()
        for (index, failure) in failures.enumerated() {
            let runtime = UsageRuntime(fetcher: FakeUsageFetcher(error: failure.error), store: store,
                                       notifier: notifier,
                                       now: { date.addingTimeInterval(Double(index + 1) * 300) },
                                       output: { _ in })
            let result = runtime.refresh(json: true)
            #expect(result.outcome == failure.outcome)
            #expect(!result.freshSnapshot)
            #expect(result.outcome.exitCode != 0)
            exits.insert(result.outcome.exitCode)
            let state = try #require(store.load().providers["codex"])
            #expect(state.snapshot == original)
            #expect(state.status?.status == failure.status)
            if failure.outcome == .throttled {
                #expect(result.retryAt == 9_000_000_000)
            }
        }
        #expect(exits.count == failures.count)
        #expect(recorder.values.filter { $0.0 == UsageRuntime.snapshotNotification }.count == 1)
    }

    @Test func unchangedSuccessfulFetchAdvancesTimeAndRevision() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let recorder = UsageRecorder()
        var runtime = UsageRuntime(fetcher: FakeUsageFetcher(response: response), store: store,
                                   notifier: RecordingUsageNotifier(recorder: recorder), now: { date },
                                   output: { _ in })
        _ = runtime.refresh()
        let first = try #require(store.load().providers["codex"]?.snapshot)
        runtime.now = { date.addingTimeInterval(60) }
        _ = runtime.refresh()
        let second = try #require(store.load().providers["codex"]?.snapshot)
        let finalState = try #require(store.load().providers["codex"])
        #expect(first.windows == second.windows)
        #expect(second.collectedAt == first.collectedAt + 60000)
        #expect(second.revision > first.revision)
        #expect(try #require(finalState.status).revision > second.revision)
        #expect(recorder.values.filter { $0.0 == UsageRuntime.snapshotNotification }.count == 2)
    }

    @Test func storageAndPublicationFailuresAreHonest() throws {
        let recorder = UsageRecorder()
        for failLoad in [true, false] {
            let runtime = UsageRuntime(fetcher: FakeUsageFetcher(response: response),
                                       store: FailingUsageStore(failLoad: failLoad),
                                       notifier: RecordingUsageNotifier(recorder: recorder), output: { _ in })
            let result = runtime.refresh()
            #expect(result.outcome == .persistenceFailure)
            #expect(!result.publicationAttempted)
            #expect(!result.freshSnapshot)
        }
        #expect(recorder.values.isEmpty)
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let runtime = UsageRuntime(fetcher: FakeUsageFetcher(response: response), store: store,
                                   notifier: RecordingUsageNotifier(recorder: recorder, fail: true),
                                   now: { date }, output: { _ in })
        let result = runtime.refresh()
        #expect(result.outcome == .publicationFailure)
        #expect(result.freshSnapshot && result.publicationAttempted)
        #expect(try store.load().providers["codex"]?.snapshot != nil)
    }

    @Test func finalPersistenceFailureDoesNotPublishFreshUsage() throws {
        let recorder = UsageRecorder()
        let store = FinalSaveFailingStore()
        let runtime = UsageRuntime(fetcher: FakeUsageFetcher(response: response), store: store,
                                   notifier: RecordingUsageNotifier(recorder: recorder), now: { date },
                                   output: { _ in })
        let result = runtime.refresh(json: true)
        #expect(result.outcome == .persistenceFailure)
        #expect(result.freshSnapshot)
        #expect(!result.publicationAttempted)
        #expect(recorder.values.map(\.0) == [UsageRuntime.statusNotification])
        #expect(try store.load().providers["codex"]?.snapshot == nil)
    }

    @Test func rawParserErrorsAreNotIncludedInOutputOrNotifications() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let recorder = UsageRecorder()
        let runtime = UsageRuntime(fetcher: FakeUsageFetcher(response: response), store: store,
                                   notifier: RecordingUsageNotifier(recorder: recorder), now: { date },
                                   parse: { _ in
                                       throw NSError(domain: "secret-token@example.com/private/path", code: 7)
                                   },
                                   output: { recorder.append("output", $0) })
        #expect(runtime.refresh(json: true).outcome == .temporaryFailure)
        #expect(!recorder.values.map(\.1).joined().contains("secret"))
    }

    @Test func missingAndMalformedWindowsNeverBecomeZero() throws {
        let store = try temporaryStore()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let notifier = RecordingUsageNotifier(recorder: UsageRecorder())
        for (index, sample) in [
            ("{\"rateLimits\":{}}", UsageOutcome.usageUnavailable),
            ("{\"rateLimits\":{\"primary\":{}}}", .temporaryFailure),
            ("{\"rateLimits\":{\"primary\":{\"usedPercent\":-1}}}", .temporaryFailure),
            ("{\"rateLimits\":{\"primary\":{\"usedPercent\":2,\"windowDurationMins\":0}}}", .temporaryFailure)
        ].enumerated() {
            let (json, expected) = sample
            let runtime = UsageRuntime(fetcher: FakeUsageFetcher(response: Data(json.utf8)), store: store,
                                       notifier: notifier, now: { date.addingTimeInterval(Double(index) * 300) },
                                       output: { _ in })
            #expect(runtime.refresh().outcome == expected)
            #expect(try store.load().providers["codex"]?.snapshot == nil)
        }
    }
}
