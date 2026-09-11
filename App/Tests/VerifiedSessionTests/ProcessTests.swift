import XCTest
@testable import VerifiedSession

final class ProcessTests: XCTestCase {
    func testSessionLockExcludesAnotherOwnerAndReleasesWithoutDeletingState() throws {
        let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:directory) }
        var first: SessionLock?=try SessionLock(directory)
        XCTAssertNotNil(first)
        XCTAssertThrowsError(try SessionLock(directory))
        first=nil
        let second=try SessionLock(directory)
        withExtendedLifetime(second) { XCTAssertTrue(FileManager.default.fileExists(atPath:directory.appendingPathComponent("owner.lock").path)) }
    }
    func testCommandCapturesStatusAndBoundsHungChild() throws {
        let result=try command("/bin/echo",["native ready"])
        XCTAssertEqual(result.status,0);XCTAssertEqual(result.output,"native ready\n")
        let start=ProcessInfo.processInfo.systemUptime
        XCTAssertThrowsError(try command("/bin/sleep",["10"],timeout:0.05))
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,4)
    }
}
