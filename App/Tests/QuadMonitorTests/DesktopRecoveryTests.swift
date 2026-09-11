import XCTest
@testable import QuadMonitor

final class DesktopRecoveryTests: XCTestCase {
    func testOnlyConfirmedDisconnectResumesAndOnlyOnce() {
        var state = DesktopRecovery()
        state.startRequested()
        state.sessionEnded(disconnected: true)
        XCTAssertFalse(state.shouldResume(devicesReady: false))
        XCTAssertTrue(state.shouldResume(devicesReady: true))
        state.sessionStarted()
        XCTAssertFalse(state.shouldResume(devicesReady: true))
        state.sessionEnded(disconnected: false)
        XCTAssertFalse(state.shouldResume(devicesReady: true))
    }

    func testWakeBeforeOrAfterOldSessionExit() {
        for wakeFirst in [true, false] {
            var state = DesktopRecovery()
            state.startRequested(); state.willSleep()
            XCTAssertFalse(state.shouldResume(devicesReady: true))
            if wakeFirst { state.didWake() }
            state.sessionEnded(disconnected: false)
            if !wakeFirst { state.didWake() }
            XCTAssertTrue(state.shouldResume(devicesReady: true))
        }
    }

    func testManualStopCancelsDisconnectAndSleepRecovery() {
        for sleep in [true, false] {
            var state = DesktopRecovery()
            state.startRequested()
            if sleep { state.willSleep() }
            else { state.sessionEnded(disconnected: true) }
            state.stopRequested()
            state.sessionEnded(disconnected: true)
            state.didWake()
            XCTAssertFalse(state.shouldResume(devicesReady: true))
        }
        var idle = DesktopRecovery()
        idle.willSleep(); idle.didWake()
        XCTAssertFalse(idle.shouldResume(devicesReady: true))
    }
}
