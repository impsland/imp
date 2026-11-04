import Foundation
import Testing
@testable import Imp

/// The main thread draws every frame: the home screen's embers and hearts, and an Imp being
/// dragged. Work that runs on a timer there shows as a stop at the timer's pace.
@MainActor @Suite struct StallTests {
    /// While the Home window is open, what macOS allows is read every couple of seconds. Those
    /// checks are calls to other processes (about 60 ms together, measured on macOS 26), so they
    /// must not run on the main thread: a refresh only starts them.
    @Test func readingWhatMacOSAllowsDoesNotHoldTheMainThread() async {
        let status = SystemStatus.shared
        await status.refresh()?.value                       // the first read, out of the way
        var worst = 0.0
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            let reading = status.refresh()
            worst = max(worst, Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            await reading?.value
        }
        // One frame at 120 Hz is about 8 ms: a refresh must cost far less than that here.
        #expect(worst < 4, "refresh held the main thread for \(worst) ms")
    }
}
