@testable import BuildrHooksCLI
@testable import BuildrHooksCore
import Testing

struct UsageSharedStateTests {
    @Test func concurrentCallbacksCoalesceAndRecoveryReplyHasOneWinner() async {
        let lifecycle = UsageWatchState()
        let recovery = UsageRecoverySession()
        let winners = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0 ..< 64 {
                group.addTask {
                    lifecycle.wake()
                    lifecycle.requestRecovery()
                    lifecycle.stop()
                    recovery.verify(.codex)
                    return recovery.beginReply(at: 1000)
                }
            }
            var winners = 0
            for await accepted in group where accepted {
                winners += 1
            }
            return winners
        }
        #expect(winners == 1)
        #expect(lifecycle.cancelled)
        #expect(lifecycle.takeTriggers() == [.wake, .recoveryRequested])
        #expect(lifecycle.takeTriggers().isEmpty && lifecycle.cancelled)
        #expect(recovery.isVerified(.codex))
        #expect(!recovery.beginReply(at: 1999))
        #expect(recovery.beginReply(at: 2000))
        recovery.unverify(.codex)
        #expect(!recovery.isVerified(.codex))
    }
}
