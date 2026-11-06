import BuildrBridgeContracts
import Foundation
import Testing

struct CompatibilityTests {
    @Test func independentConsumerRunsCommonValidAndInvalidV1Fixtures() throws {
        let results = try BridgeCompatibilityFixtures.verify()
        #expect(results.count == 55)
        #expect(results.contains { $0.expectedError == nil })
        #expect(results.contains { $0.expectedError != nil })
        for result in results {
            #expect(result.matched, "\(result.name): \(String(describing: result.actualError))")
        }
        let packet = try BridgeCompatibilityFixtures.preparedExample()
        let generated = try BridgeCompatibilityFixtures.finalizationExample()
        try BridgeValidator.validate(generated, against: packet)
        #expect(packet.rollupMetrics.inputTokens == .unavailable("not reported"))
        #expect(packet.rollupMetrics.outputTokens == .available(0))
    }
}
