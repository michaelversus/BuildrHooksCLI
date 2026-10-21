@testable import BuildrHooksCore
import Foundation
import Testing

struct ClaudeUsageContractTests {
    private let now = Date(timeIntervalSince1970: 1000)
    private let snapshot = #"""
    {"schemaVersion":2,"cliVersion":"1.2.8","provider":"claude","scope":"provider",
    "revision":5,"receivedAt":900000,"windows":[{"limitCode":"claude","role":"primary",
    "durationMinutes":300,"usedPercent":0}]}
    """#
    private let status = #"""
    {"schemaVersion":2,"cliVersion":"1.2.8","provider":"claude","scope":"provider",
    "revision":6,"observedAt":950000,"status":"ready","latestInvalidationRevision":0,
    "retainedSnapshotRevision":5,"receivedAt":900000,"replayRequestID":"recovery-1"}
    """#

    @Test func claudeReceiptContractRoundTripsWithoutCollectionTime() throws {
        let value = try UsageWire().decodeSnapshot(snapshot, now: now)
        let encoded = try UsageWire().encode(value, now: now)
        let object = try #require(JSONSerialization.jsonObject(with: Data(encoded.utf8)) as? [String: Any])
        #expect(object["receivedAt"] as? Int == 900_000)
        #expect(object["scope"] as? String == "provider")
        #expect(object["collectedAt"] == nil)
        #expect(value.windows[0].usedPercent == 0)
        #expect(value.collectedAt == nil && value.receivedAt == 900_000)
        let state = try UsageWire().decodeStatus(status, now: now, after: 5)
        let statusObject = try #require(try JSONSerialization.jsonObject(
            with: Data(UsageWire().encode(state, now: now).utf8)
        ) as? [String: Any])
        #expect(statusObject["receivedAt"] as? Int == 900_000)
        #expect(statusObject["retainedSnapshotRevision"] as? Int == 5)
        #expect(statusObject["replayRequestID"] as? String == "recovery-1")
        // Status ordering does not advance the independently supplied snapshot floor.
        #expect(try UsageWire().decodeSnapshot(snapshot, now: now, after: 4).revision == 5)
    }

    @Test func quotaFreeAndClearCarryExplicitAuthoritativeAbsence() throws {
        let payload = #"""
        {"schemaVersion":2,"cliVersion":"1.2.8","provider":"claude","scope":"provider",
        "revision":7,"observedAt":950000,"status":"usage_unavailable",
        "latestInvalidationRevision":6,"retainedSnapshotRevision":null}
        """#
        let value = try UsageWire().decodeStatus(payload, now: now)
        let encoded = try UsageWire().encode(value, now: now)
        #expect(encoded.contains("\"retainedSnapshotRevision\":null"))
        #expect(!encoded.contains("receivedAt"))
        #expect(throws: (any Error).self) {
            try UsageWire().decodeSnapshot(snapshot, now: now, invalidation: 6)
        }
    }
}

extension ClaudeUsageContractTests {
    @Test func sharedCrossVersionFixturesAreCanonicalAndRetainTypedProvenance() throws {
        let wire = UsageWire()
        for name in ["codex-v1-snapshot", "claude-v2-snapshot"] {
            let payload = try fixture(name)
            let value = try wire.decodeSnapshot(payload, now: now)
            #expect(try wire.encode(value, now: now) == payload)
            #expect(value.timestamp == (value.provider == .codex ? .collected(900_000) : .received(900_000)))
        }
        for name in ["codex-v1-status", "claude-v2-status", "claude-v2-absence"] {
            let payload = try fixture(name)
            #expect(try wire.encode(wire.decodeStatus(payload, now: now), now: now) == payload)
        }
    }

    @Test func incompatibleScopesVersionsAndTimestampMeaningsAreRejected() throws {
        for (key, value) in [("schemaVersion", 1 as Any), ("schemaVersion", 3), ("provider", "codex"),
                             ("scope", "account"), ("scope", NSNull()), ("collectedAt", 900_000),
                             ("receivedAt", -1), ("receivedAt", 1_120_001), ("receivedAt", true),
                             ("replayRequestID", "private@example.com"), ("replayRequestID", ""),
                             ("replayRequestID", String(repeating: "a", count: 129))] {
            #expect(throws: (any Error).self) {
                try UsageWire().decodeSnapshot(replacing(snapshot, key: key, value: value), now: now)
            }
        }
        let codex = try fixture("codex-v1-snapshot")
        #expect(throws: (any Error).self) {
            try UsageWire().decodeSnapshot(replacing(codex, key: "provider", value: "claude"), now: now)
        }
        let huge = snapshot + String(repeating: " ", count: UsageWire.maximumBytes)
        #expect(throws: (any Error).self) { try UsageWire().decodeSnapshot(huge, now: now) }
        for percent in ["0" as Any, true, -1, 100.01] {
            var object = try #require(JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as? [String: Any])
            object["windows"] = [["limitCode": "claude", "role": "primary", "durationMinutes": 300,
                                  "usedPercent": percent]]
            let payload = try jsonString(for: object)
            #expect(throws: (any Error).self) { try UsageWire().decodeSnapshot(payload, now: now) }
        }
    }

    @Test func authoritativeStatusesRequireExplicitConsistentRetentionAndBoundedCorrelation() throws {
        for (key, value) in [("retainedSnapshotRevision", NSNull() as Any),
                             ("retainedSnapshotRevision", 0), ("retainedSnapshotRevision", 7),
                             ("latestInvalidationRevision", 5), ("scope", "account"),
                             ("cliVersion", NSNull()), ("receivedAt", 950_001),
                             ("status", "usage_unavailable"), ("replayRequestID", "/private/path")] {
            #expect(throws: (any Error).self) {
                try UsageWire().decodeStatus(replacing(status, key: key, value: value), now: now)
            }
        }
        var object = try #require(JSONSerialization.jsonObject(with: Data(status.utf8)) as? [String: Any])
        object.removeValue(forKey: "retainedSnapshotRevision")
        let payload = try jsonString(for: object)
        #expect(throws: (any Error).self) { try UsageWire().decodeStatus(payload, now: now) }
        // Malformed capture may advance only status while retaining the original receipt/revision.
        let failure = try UsageWire().decodeStatus(replacing(status, key: "status", value: "temporary_failure"),
                                                   now: now)
        #expect(failure.retainedSnapshotRevision == 5 && failure.receivedAt == 900_000)
        let request = try UsageReplayRequest(replayRequestID: "recovery-1")
        #expect(try UsageReplayRequest(userInfo: request.userInfo) == request)
        for info: [AnyHashable: Any] in [[:], ["replayRequestID": true], ["replayRequestID": ""],
                                         ["replayRequestID": "a", "provider": "claude"]] {
            #expect(throws: (any Error).self) { try UsageReplayRequest(userInfo: info) }
        }
    }

    private func fixture(_ name: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/usage/\(name).json")
        return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .newlines)
    }

    private func replacing(_ payload: String, key: String, value: Any) throws -> String {
        var object = try #require(JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any])
        object[key] = value
        return try jsonString(for: object)
    }

    private func jsonString(for object: Any) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return try #require(String(bytes: data, encoding: .utf8))
    }
}
