import Foundation

/// Only usage fields are decoded. Identity, display labels, credits and other raw fields are discarded.
public struct CodexUsageParser: Sendable {
    private enum CodingKeys: String, CodingKey { case rateLimits, rateLimitsByLimitId }

    private struct Response: Decodable {
        let rateLimits: Bucket?
        let rateLimitsByLimitId: [String: Bucket]?
        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            rateLimitsByLimitId = try container.decodeIfPresent([String: Bucket].self, forKey: .rateLimitsByLimitId)
            if let multiple = rateLimitsByLimitId, !multiple.isEmpty {
                rateLimits = nil
            } else {
                rateLimits = try container.decodeIfPresent(Bucket.self, forKey: .rateLimits)
            }
        }
    }

    private struct Bucket: Decodable {
        let limitId: String?
        let primary: Window?
        let secondary: Window?
    }

    private struct Window: Decodable {
        let usedPercent: Double
        let windowDurationMins: Int64?
        let resetsAt: Int64?
    }

    public init() {}
    public func windows(from data: Data) throws -> [UsageWindow] {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let buckets: [(String, Bucket)] = if let multiple = response.rateLimitsByLimitId, !multiple.isEmpty {
            multiple.keys.sorted().compactMap { key in multiple[key].map { (key, $0) } }
        } else {
            if let legacy = response.rateLimits {
                [(legacy.limitId ?? "codex", legacy)]
            } else {
                []
            }
        }
        return try buckets.flatMap { code, bucket in
            try [("primary", bucket.primary), ("secondary", bucket.secondary)].compactMap { role, value in
                guard let value else { return nil }
                let reset: Int64?
                if let seconds = value.resetsAt {
                    let conversion = seconds.multipliedReportingOverflow(by: 1000)
                    guard !conversion.overflow else { throw UsageWireError.invalidPayload }
                    reset = conversion.partialValue
                } else {
                    reset = nil
                }
                return UsageWindow(limitCode: code, role: role, usedPercent: value.usedPercent,
                                   durationMinutes: value.windowDurationMins, resetsAt: reset)
            }
        }
    }
}
