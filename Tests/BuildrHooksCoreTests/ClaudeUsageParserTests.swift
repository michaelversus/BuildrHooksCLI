@testable import BuildrHooksCore
import Foundation
import Testing

struct ClaudeUsageParserTests {
    @Test func absenceNullAndUnknownFieldsAreValidQuotaAbsence() throws {
        for input in ["{}", #"{"rate_limits":null}"#, #"{"rate_limits":{}}"#,
                      #"{"rate_limits":{"five_hour":null,"seven_day":null,"unknown":{"used_percentage":8}}}"#,
                      #"{"cost":{"total_cost_usd":20},"accountId":"ignored","rate_limits":{}}"#] {
            #expect(try parse(input).isEmpty)
        }
    }

    @Test func zeroFractionalAndSingleWindowsRetainRealResetAndIdentity() throws {
        let windows = try parse(#"""
        {"rate_limits":{"five_hour":{"used_percentage":0,"resets_at":123},
        "seven_day":{"used_percentage":37.125,"resets_at":null}}}
        """#)
        #expect(windows == [UsageWindow(limitCode: "claude", role: "primary", usedPercent: 0,
                                        durationMinutes: 300, resetsAt: 123_000),
                            UsageWindow(limitCode: "claude", role: "secondary", usedPercent: 37.125,
                                        durationMinutes: 10080)])
        #expect(try parse(#"{"rate_limits":{"seven_day":{"used_percentage":100}}}"#).count == 1)
        let boundary = try parse(#"""
        {"rate_limits":{"five_hour":{"used_percentage":0.00000001,"resets_at":9223372036854775}}}
        """#)
        #expect(boundary.first?.resetsAt == 9_223_372_036_854_775_000)
    }

    @Test func malformedTypeRangeAndResetRejectWholeCallback() {
        for input in ["null", "[]", #"{"rate_limits":[]}"#, #"{"rate_limits":false}"#,
                      #"{"rate_limits":"missing"}"#] {
            #expect(throws: (any Error).self) { try parse(input) }
        }
        for window in ["[]", "false", "2", "{}", #"{"used_percentage":null}"#,
                       #"{"used_percentage":true}"#, #"{"used_percentage":"0"}"#,
                       #"{"used_percentage":-0.1}"#, #"{"used_percentage":100.001}"#,
                       #"{"used_percentage":1e999}"#, #"{"used_percentage":0,"resets_at":true}"#,
                       #"{"used_percentage":0,"resets_at":"123"}"#,
                       #"{"used_percentage":0,"resets_at":-1}"#,
                       #"{"used_percentage":0,"resets_at":1.5}"#,
                       #"{"used_percentage":0,"resets_at":9223372036854776}"#,
                       #"{"used_percentage":0,"resets_at":1e999}"#] {
            #expect(throws: (any Error).self) {
                try parse("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":2},\"seven_day\":" + window + "}}")
            }
        }
        #expect(throws: (any Error).self) {
            try parse("{}" + String(repeating: " ", count: ClaudeUsageParser.maximumBytes))
        }
    }

    private func parse(_ input: String) throws -> [UsageWindow] {
        try ClaudeUsageParser().windows(from: Data(input.utf8))
    }
}
