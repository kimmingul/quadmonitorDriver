import XCTest
@testable import VerifiedDisplayCore

final class FramePacerTests: XCTestCase {
    func testOneShotWaitDoesNotReuseWakeAfterOverrun() {
        let waiter = FrameWaiter()
        for delay in [0.003, -0.1, 0.005, -0.1, 0.003] {
            let deadline = ProcessInfo.processInfo.systemUptime + delay
            waiter.wait(untilUptime: deadline)
            XCTAssertGreaterThanOrEqual(ProcessInfo.processInfo.systemUptime, deadline)
        }
    }

    func testLateWakeDoesNotAccumulateIntoNextDeadline() {
        var pacer = FramePacer(fps: 60, startedAt: 10)
        XCTAssertEqual(pacer.deadline(completedAt: 10.005), 10 + 1.0/60, accuracy: 1e-9)
        // The first wake was 2.4 ms late. The second target stays on its timeline.
        XCTAssertEqual(pacer.deadline(completedAt: 10.024), 10 + 2.0/60, accuracy: 1e-9)
        XCTAssertEqual(pacer.deadline(completedAt: 10.040), 10.05, accuracy: 1e-9)
    }

    func testLongTransferResumesImmediatelyWithoutCatchUpBurst() {
        var pacer = FramePacer(fps: 60, startedAt: 10)
        XCTAssertEqual(pacer.deadline(completedAt: 10.080), 10.080, accuracy: 1e-9)
        XCTAssertEqual(pacer.deadline(completedAt: 10.084), 10.080 + 1.0/60, accuracy: 1e-9)
        XCTAssertEqual(pacer.deadline(completedAt: 10.104), 10.080 + 2.0/60, accuracy: 1e-9)
    }
}
