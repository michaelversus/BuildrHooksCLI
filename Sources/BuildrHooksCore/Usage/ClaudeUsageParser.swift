import CoreFoundation
import Foundation

/// Extract only documented quota facts. The original callback is never retained.
public struct ClaudeUsageParser: Sendable {
    public static let maximumBytes = 1024 * 1024
    public init() {}

    public func windows(from data: Data) throws -> [UsageWindow] {
        guard data.count <= Self.maximumBytes,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageWireError.invalidPayload
        }
        guard let raw = object["rate_limits"], !(raw is NSNull) else { return [] }
        guard let limits = raw as? [String: Any] else { throw UsageWireError.invalidPayload }
        return try [("five_hour", "primary", Int64(300)), ("seven_day", "secondary", Int64(10080))]
            .compactMap { key, role, duration in
                guard let raw = limits[key], !(raw is NSNull) else { return nil }
                guard let window = raw as? [String: Any], let number = window["used_percentage"] as? NSNumber,
                      CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      (0 ... 100).contains(number.doubleValue) else { throw UsageWireError.invalidPayload }
                return try UsageWindow(limitCode: "claude", role: role, usedPercent: number.doubleValue,
                                       durationMinutes: duration, resetsAt: reset(window["resets_at"]))
            }
    }

    private func reset(_ raw: Any?) throws -> Int64? {
        guard let raw, !(raw is NSNull) else { return nil }
        guard let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, var seconds = Decimal(string: number.stringValue),
              seconds >= 0 else { throw UsageWireError.invalidPayload }
        var integral = Decimal()
        NSDecimalRound(&integral, &seconds, 0, .plain)
        guard integral == seconds, seconds <= Decimal(Int64.max / 1000) else {
            throw UsageWireError.invalidPayload
        }
        return NSDecimalNumber(decimal: seconds).int64Value * 1000
    }
}
