import Testing
@testable import ImpDesign

@Suite struct NoticeTests {
    @Test func finishedStatesResetAfterTheNoticeTime() {
        #expect(ActionState.done.resetDelay == .seconds(Behavior.noticeSeconds))
        #expect(ActionState.failed.resetDelay == .seconds(Behavior.noticeSeconds))
        #expect(ActionState.idle.resetDelay == nil)
        #expect(ActionState.working.resetDelay == nil)
    }

    @Test func resultMapsToDoneOrFailed() {
        #expect(ActionState.result(true) == .done)
        #expect(ActionState.result(false) == .failed)
    }

    @Test func noticesHaveDistinctIdentities() {
        #expect(ImpNotice.error("x") != ImpNotice.error("x"))
        #expect(ImpNotice.warning("x").symbol != ImpNotice.error("x").symbol)
    }
}
