@testable import BuildrHooksCore
import Foundation
import Testing

struct UsageWireTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private var window: UsageWindow {
        UsageWindow(limitCode: "codex-model", role: "primary", usedPercent: 125,
                    durationMinutes: nil, resetsAt: 9_000_000)
    }

    @Test func optionalPublisherVersionRemainsCompatibleWithOlderConsumers() throws {
        // The v1 consumer shape before cliVersion was introduced.
        struct OldSnapshot: Decodable {
            let schemaVersion: Int
            let provider: UsageProvider
            let revision: UInt64
            let collectedAt: Int64
            let windows: [UsageWindow]
        }
        struct OldStatus: Decodable {
            let schemaVersion: Int
            let provider: UsageProvider
            let revision: UInt64
            let observedAt: Int64
            let status: UsageStatusCode
            let latestInvalidationRevision: UInt64
        }
        for version in [nil, "1.2.7", "2.0.0-alpha.17+build.2"] as [String?] {
            let snapshot = UsageSnapshot(provider: .codex, revision: 5, collectedAt: 1, windows: [window],
                                         cliVersion: version)
            let status = UsageCollectionStatus(provider: .codex, revision: 6, observedAt: 2, status: .ready,
                                               latestInvalidationRevision: 3, cliVersion: version)
            let snapshotPayload = try UsageWire().encode(snapshot, now: now)
            let statusPayload = try UsageWire().encode(status, now: now)
            #expect(try UsageWire().decodeSnapshot(snapshotPayload, now: now) == snapshot)
            #expect(try UsageWire().decodeStatus(statusPayload, now: now) == status)
            let oldSnapshot = try JSONDecoder().decode(OldSnapshot.self, from: Data(snapshotPayload.utf8))
            let oldStatus = try JSONDecoder().decode(OldStatus.self, from: Data(statusPayload.utf8))
            #expect(oldSnapshot.schemaVersion == 1 && oldSnapshot.collectedAt == 1 && oldSnapshot.revision == 5)
            #expect(oldSnapshot.windows == [window] && oldSnapshot.provider == .codex)
            #expect(oldStatus.schemaVersion == 1 && oldStatus.observedAt == 2 && oldStatus.revision == 6)
            #expect(oldStatus.latestInvalidationRevision == 3 && oldStatus.status == .ready
                && oldStatus.provider == .codex)
            #expect(snapshotPayload.contains("cliVersion") == (version != nil))
        }
    }

    @Test func publisherVersionRejectsMalformedIdentifyingAndOversizedValues() throws {
        for version in ["", "01.2.3", "1.2", "1.2.3-01", "1.2.3\n", "1.2.3\u{2028}", "1.2.3\u{0085}",
                        "secret@example.com", "/private/path",
                        "1.2.3+" + String(repeating: "a", count: 128)] {
            let snapshot = UsageSnapshot(provider: .codex, revision: 1, collectedAt: 1, windows: [window],
                                         cliVersion: version)
            let status = UsageCollectionStatus(provider: .codex, revision: 2, observedAt: 1, status: .ready,
                                               cliVersion: version)
            #expect(throws: (any Error).self) { try UsageWire().encode(snapshot, now: now) }
            #expect(throws: (any Error).self) { try UsageWire().encode(status, now: now) }
            let snapshotData = try JSONEncoder().encode(snapshot)
            let statusData = try JSONEncoder().encode(status)
            let rawSnapshot = try #require(String(bytes: snapshotData, encoding: .utf8))
            let rawStatus = try #require(String(bytes: statusData, encoding: .utf8))
            #expect(throws: (any Error).self) { try UsageWire().decodeSnapshot(rawSnapshot, now: now) }
            #expect(throws: (any Error).self) { try UsageWire().decodeStatus(rawStatus, now: now) }
        }
        let snapshot = UsageSnapshot(provider: .codex, revision: 1, collectedAt: 1, windows: [window],
                                     cliVersion: "1.2.7")
        let payload = try UsageWire().encode(snapshot, now: now)
        let boundary = payload + String(repeating: " ", count: UsageWire.maximumBytes - payload.utf8.count)
        #expect(try UsageWire().decodeSnapshot(boundary, now: now) == snapshot)
        #expect(throws: (any Error).self) { try UsageWire().decodeSnapshot(boundary + " ", now: now) }
    }

    @Test func oldObservationsFutureResetsAndSeparateOrderingAreValid() throws {
        let wire = UsageWire()
        let snapshot = UsageSnapshot(provider: .codex, revision: 5, collectedAt: 1, windows: [window])
        let payload = try wire.encode(snapshot, now: now)
        #expect(try wire.decodeSnapshot(payload, now: now, after: 4, invalidation: 3) == snapshot)
        #expect(throws: (any Error).self) { try wire.decodeSnapshot(payload, now: now, invalidation: 5) }
        #expect(throws: (any Error).self) { try wire.decodeSnapshot(payload, now: now, after: 5) }
        let status = UsageCollectionStatus(provider: .codex, revision: 10, observedAt: 1_120_000,
                                           status: .throttled, retryAt: 99_000_000, latestInvalidationRevision: 3)
        let statusPayload = try wire.encode(status, now: now)
        #expect(try wire.decodeStatus(statusPayload, now: now, after: 9) == status)
        // A newer status does not change the snapshot stream's floor.
        #expect(try wire.decodeSnapshot(payload, now: now, after: 4).revision == 5)
        #expect(throws: (any Error).self) { try wire.decodeStatus(statusPayload, now: now, after: 10) }
    }

    @Test func malformedUnsupportedAndFutureObservationsAreRejected() throws {
        let wire = UsageWire()
        let snapshot = UsageSnapshot(provider: .codex, revision: 1, collectedAt: 1_120_001, windows: [window])
        #expect(throws: (any Error).self) { try wire.encode(snapshot, now: now) }
        let status = UsageCollectionStatus(provider: .codex, revision: 1, observedAt: 1_120_001,
                                           status: .ready, retryAt: nil, latestInvalidationRevision: 0)
        #expect(throws: (any Error).self) { try wire.encode(status, now: now) }
        let valid = UsageSnapshot(provider: .codex, revision: 1, collectedAt: 1000, windows: [window])
        let payload = try wire.encode(valid, now: now)
        #expect(throws: (any Error).self) {
            let unsupported = payload.replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":2")
            _ = try wire.decodeSnapshot(unsupported, now: now)
        }
        let boundary = payload + String(repeating: " ", count: UsageWire.maximumBytes - payload.utf8.count)
        #expect(try wire.decodeSnapshot(boundary, now: now) == valid)
        #expect(throws: (any Error).self) { try wire.decodeSnapshot(boundary + " ", now: now) }
        let duplicate = UsageSnapshot(provider: .codex, revision: 1, collectedAt: 1000, windows: [window, window])
        #expect(throws: (any Error).self) { try wire.encode(duplicate, now: now) }
        #expect(throws: (any Error).self) { try wire.decodeSnapshot("{}", now: now) }
        #expect(throws: (any Error).self) { try wire.decodeStatus("{}", now: now) }
        #expect(throws: (any Error).self) { try wire.decodeSnapshot(String(repeating: " ", count: 65537), now: now) }
        let huge = UsageSnapshot(provider: .codex, revision: 1, collectedAt: 1000,
                                 windows: (0 ..< 1000).map {
                                     UsageWindow(limitCode: "codex-\($0)", role: "primary", usedPercent: 125,
                                                 durationMinutes: 17, resetsAt: 9_000_000)
                                 })
        #expect(throws: (any Error).self) { try wire.encode(huge, now: now) }
    }

    @Test func invalidPercentDurationAndIdentifyingCodesAreRejected() {
        for percent in [-1.0, .infinity, .nan] {
            let value = UsageWindow(limitCode: "codex", role: "primary", usedPercent: percent,
                                    durationMinutes: nil, resetsAt: nil)
            let snapshot = UsageSnapshot(provider: .codex, revision: 1, collectedAt: 0, windows: [value])
            #expect(throws: (any Error).self) { try UsageWire().encode(snapshot, now: now) }
        }
        for (code, duration) in [("secret@example.com", Int64(5)), ("codex", 0), ("codex", -1)] {
            let value = UsageWindow(limitCode: code, role: "primary", usedPercent: 0,
                                    durationMinutes: duration, resetsAt: nil)
            let snapshot = UsageSnapshot(provider: .codex, revision: 1, collectedAt: 0, windows: [value])
            #expect(throws: (any Error).self) { try UsageWire().encode(snapshot, now: now) }
        }
    }

    @Test func multiBucketResponseDoesNotRequireLegacyData() throws {
        for legacy in ["", "\"rateLimits\":null,", "\"rateLimits\":\"malformed\","] {
            let json = "{" + legacy + "\"rateLimitsByLimitId\":{\"review\":{\"primary\":{\"usedPercent\":8}}}}"
            #expect(try CodexUsageParser().windows(from: Data(json.utf8)).first?.limitCode == "review")
        }
    }

    @Test func legacyFallbackPreservesUnknownMetadataWithoutInventingDuration() throws {
        let data = Data("{\"rateLimits\":{\"primary\":{\"usedPercent\":7}}}".utf8)
        let windows = try CodexUsageParser().windows(from: data)
        #expect(windows.count == 1)
        #expect(windows[0].limitCode == "codex")
        #expect(windows[0].durationMinutes == nil)
        #expect(windows[0].resetsAt == nil)
    }
}
