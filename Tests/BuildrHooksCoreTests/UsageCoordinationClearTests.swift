@testable import BuildrHooksCore
import Darwin
import Foundation
import Testing

extension UsageCoordinationTests {
    @Test func mixedPrivateCommandsKeepTheirOwnResultsAndClearBoundary() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let server = UsageCoordination(cacheURL: store.fileURL)
        #expect(try server.acquire())
        try server.startServing()
        defer { server.close() }
        let provider = CoordinatedProvider()
        let ownerRuntime = runtime(provider, store)
        var clients: [Int32] = []
        defer { clients.forEach { Darwin.close($0) } }
        for operation in [UsagePrivateRequest.Operation.refresh, .clear, .refresh] {
            let client = try connect(server)
            clients.append(client)
            #expect(try UsageCoordination.sendFrame(
                client, data: JSONEncoder().encode(UsagePrivateRequest(operation: operation)),
                deadline: UsageCoordination.time + 1, cancelled: { false }
            ))
        }
        server.serve { ownerRuntime.dispatch($0) }
        var outcomes: [UsageOutcome] = []
        for client in clients {
            var response = Data()
            #expect(UsageCoordination.readFrame(client, data: &response) == .complete)
            try outcomes.append(JSONDecoder().decode(UsageRefreshResult.self, from: response).outcome)
        }
        #expect(outcomes == [.refreshed, .cleared, .throttled])
        #expect(try store.load().providers["codex"]?.snapshot == nil)
        #expect(provider.count == 1)
    }

    @Test func clearUsesExclusiveFallbackWithoutFetchingAndRunningOwnerDelegation() throws {
        let store = fixture()
        defer { try? FileManager.default.removeItem(at: store.fileURL.deletingLastPathComponent()) }
        let provider = CoordinatedProvider()
        let ownerRuntime = runtime(provider, store)
        #expect(UsageCoordination(cacheURL: store.fileURL).refresh(runtime: ownerRuntime).outcome == .refreshed)
        let first = UsageCoordination(cacheURL: store.fileURL).clear(runtime: ownerRuntime)
        #expect(first.outcome == .cleared && first.localCleared && first.publicationAttempted)
        #expect(provider.count == 1)
        let marker = try #require(store.load().providers["codex"]?.latestInvalidationRevision)
        let server = UsageCoordination(cacheURL: store.fileURL)
        #expect(try server.acquire())
        try server.startServing()
        defer { server.close() }
        let fallback = CoordinatedProvider()
        let fallbackRuntime = runtime(fallback, store)
        let results = CoordinationCapture()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            let result = UsageCoordination(cacheURL: store.fileURL).clear(runtime: fallbackRuntime, timeout: 2)
            results.append("\(result.outcome.rawValue):\(result.localCleared):\(result.publicationAttempted)")
            group.leave()
        }
        let deadline = UsageCoordination.time + 2
        while results.output.isEmpty, UsageCoordination.time < deadline {
            server.serve { ownerRuntime.dispatch($0) }
            Thread.sleep(forTimeInterval: 0.005)
        }
        #expect(group.wait(timeout: .now() + 1) == .success)
        #expect(results.output == ["cleared:true:true"])
        #expect(fallback.count == 0 && provider.count == 1)
        #expect(try store.load().providers["codex"]?.snapshot == nil)
        #expect(try #require(store.load().providers["codex"]?.latestInvalidationRevision) > marker)
    }
}
