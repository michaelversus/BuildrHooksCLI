import Foundation

/// A portable corpus. The JSON files and expected results are shared with app consumers.
public enum BridgeCompatibilityFixtures {
    public static var directory: URL {
        Bundle.module.resourceURL!.appendingPathComponent("Fixtures", isDirectory: true)
    }

    public static func verify() throws -> [BridgeFixtureResult] {
        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        return try urls.map { try verify(Data(contentsOf: $0)) }
    }

    public static func verify(_ data: Data) throws -> BridgeFixtureResult {
        let header = try JSONDecoder().decode(FixtureHeader.self, from: data)
        var actual: BridgeValidationError?
        do {
            let fixture = try JSONDecoder().decode(BridgeFixture.self, from: data)
            try BridgeValidator.validate(fixture.request, expectedScope: fixture.expectedScope,
                                         preparedPacket: fixture.packet)
            if let response = fixture.response {
                try BridgeValidator.validate(response, for: fixture.request)
            }
        } catch let error as BridgeValidationError {
            actual = error
        } catch is DecodingError {
            actual = .invalidPayload
        }
        return BridgeFixtureResult(name: header.name, expectedError: header.expectedError, actualError: actual)
    }

    public static func preparedExample() throws -> BridgeEvidencePacket {
        let fixture = try load("prepare-partial")
        guard case let .prepared(packet) = fixture.response?.body else {
            throw BridgeValidationError.invalidPayload
        }
        return packet
    }

    public static func finalizationExample() throws -> BridgeGeneratedContent {
        let fixture = try load("finalize-success")
        guard case let .finalize(content) = fixture.request.body else {
            throw BridgeValidationError.invalidPayload
        }
        return content
    }

    private static func load(_ name: String) throws -> BridgeFixture {
        try JSONDecoder().decode(BridgeFixture.self, from: Data(contentsOf: directory
                .appendingPathComponent(name + ".json")))
    }
}

public struct BridgeFixture: Codable, Sendable {
    public let name: String
    public let expectedError: BridgeValidationError?
    public let expectedScope: BridgeScope
    public let request: BridgeRequest
    public let response: BridgeResponse?
    public let packet: BridgeEvidencePacket?
}

public struct BridgeFixtureResult: Sendable {
    public let name: String
    public let expectedError: BridgeValidationError?
    public let actualError: BridgeValidationError?

    public var matched: Bool {
        expectedError == actualError
    }
}

private struct FixtureHeader: Decodable {
    let name: String
    let expectedError: BridgeValidationError?
}
