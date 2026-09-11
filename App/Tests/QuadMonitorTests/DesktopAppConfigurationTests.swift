import XCTest
@testable import QuadMonitor

final class DesktopAppConfigurationTests: XCTestCase {
    func defaults(_ root: URL) -> [String:String] {
        DesktopAppConfiguration.bundledDefaults(bundle:URL(fileURLWithPath:"/Volumes/Other Disk/Quad Monitor.app"),support:root)
    }
    func testInstalledAppResolvesNativeHelpersAndWritesOutsideBundle() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var c=try DesktopAppConfiguration.parse(["app"],defaults:defaults(root))
        XCTAssertEqual(c.coordinator.path,"/Volumes/Other Disk/Quad Monitor.app/Contents/Helpers/VerifiedSession")
        XCTAssertEqual(c.controlDirectory,root.appendingPathComponent("Quad Monitor/control"))
        XCTAssertEqual(c.logsDirectory,root.appendingPathComponent("Quad Monitor/runs"))
        XCTAssertEqual(c.fps,60);XCTAssertFalse(c.startImmediately)
        XCTAssertFalse(c.workerArguments().contains(where:{$0.contains(".py")}))
        c.fps=30;try c.savePreferences()
        XCTAssertEqual(try DesktopAppConfiguration.parse(["app"],defaults:defaults(root)).fps,30)
    }
    func testWorkerIsBoundToAppAndUsesSameResourcesForReconnect() throws {
        let c=try DesktopAppConfiguration.parse(["app"],defaults:defaults(URL(fileURLWithPath:"/tmp/test-state")))
        let args=c.workerArguments(ownerPID:12345)
        XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of:"--owner-pid"))+1],"12345")
        XCTAssertEqual(Array(args.prefix(2)),Array(c.presenceArguments.prefix(2)))
        XCTAssertTrue(c.presenceArguments.contains(c.controlDirectory.path))
        XCTAssertFalse(c.workerArguments().contains("--owner-pid"))
    }
    func testInvalidAndLegacyOptionsAreRejected() {
        for flag in ["--hardware","--bulk-probe=1","--fps=0","--fps=61","--unknown","--python=/tmp/python"] {
            XCTAssertThrowsError(try DesktopAppConfiguration.parse(["app",flag],defaults:defaults(URL(fileURLWithPath:"/tmp/test-state"))))
        }
        XCTAssertThrowsError(try DesktopAppConfiguration.parse(["app"],defaults:[:]))
    }
    func testDemoAndStartUseNativeContinuousSession() throws {
        let c=try DesktopAppConfiguration.parse(["app","--start","--demo","--fps=10"],defaults:defaults(URL(fileURLWithPath:"/tmp/test-state")))
        XCTAssertTrue(c.startImmediately);XCTAssertEqual(c.fps,10)
        for flag in ["--continuous","--send","--takeover-vendor","--demo"] { XCTAssertTrue(c.workerArguments().contains(flag)) }
    }
    func testPerformancePreferencesPersistAndCLIFrameRateWins() throws {
        let root=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:root) }
        var c=try DesktopAppConfiguration.parse(["app"],defaults:defaults(root))
        c.fps=60;c.selectedPanels=["left","top"];c.performance.workers=8
        c.performance.damage = .metal;c.performance.compression = .full
        c.performance.reuseBuffers=true;c.performance.adaptiveWorkers=true;c.performance.overlapPreparation=true
        try c.savePreferences()
        let loaded=try DesktopAppConfiguration.parse(["app","--fps=30"],defaults:defaults(root))
        XCTAssertEqual(loaded.fps,30);XCTAssertEqual(loaded.selectedPanels,["left","top"])
        XCTAssertEqual(loaded.performance,c.performance);XCTAssertFalse(loaded.startImmediately)
        for flag in ["--reuse-buffers","--adaptive-workers","--overlap-preparation"] {
            let args=loaded.workerArguments();XCTAssertEqual(args[try XCTUnwrap(args.firstIndex(of:flag))+1],"1")
        }
    }
}
