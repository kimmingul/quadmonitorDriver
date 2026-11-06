import XCTest
import CoreGraphics
@testable import QuadMonitor

final class DockGuardLayoutTests: XCTestCase {
    // Quad layout around a 1728x1117 main display: side panels are top-aligned
    // and 83pt taller, the top panel sits above the main display.
    let main=CGRect(x:0,y:0,width:1728,height:1117)
    let right=CGRect(x:1728,y:0,width:1920,height:1200)
    let left=CGRect(x:-1920,y:0,width:1920,height:1200)
    let top=CGRect(x:-96,y:-1200,width:1920,height:1200)
    var layout: DockGuardLayout { DockGuardLayout(main:main,others:[right,left,top]) }

    func testFreeBottomEdgesOfOtherDisplaysAreBlockedIncludingCorners() {
        for point in [CGPoint(x:2688,y:1199),CGPoint(x:3647,y:1199),CGPoint(x:1728,y:1199.5),
                      CGPoint(x:-1920,y:1199),CGPoint(x:-960,y:1197)] {
            XCTAssertTrue(layout.blocks(point),"\(point)")
        }
        XCTAssertFalse(layout.blocks(CGPoint(x:2688,y:1196.9)),"just above the guard band")
    }

    func testMainDisplayAndEdgesAboveAnotherDisplayStayFree() {
        XCTAssertFalse(layout.blocks(CGPoint(x:864,y:1116)),"main display keeps its Dock edge")
        XCTAssertFalse(layout.blocks(CGPoint(x:864,y:-1)),"top panel over the main display")
        // A narrower main display leaves the top panel's bottom edge exposed at both ends.
        let narrow=DockGuardLayout(main:CGRect(x:0,y:0,width:1470,height:956),
                                   others:[CGRect(x:-225,y:-1200,width:1920,height:1200)])
        XCTAssertTrue(narrow.blocks(CGPoint(x:-100,y:-1)))
        XCTAssertTrue(narrow.blocks(CGPoint(x:1600,y:-1)))
        XCTAssertFalse(narrow.blocks(CGPoint(x:700,y:-1)))
    }

    func testDockLocationAndRecallPoint() {
        XCTAssertFalse(layout.dockIsAway(CGRect(x:41,y:1036,width:1646,height:71)))
        XCTAssertTrue(layout.dockIsAway(CGRect(x:1775,y:1113,width:1826,height:77)))
        XCTAssertEqual(layout.mainEdgePoint,CGPoint(x:864,y:1116))
        let below=DockGuardLayout(main:main,others:[CGRect(x:0,y:1117,width:1728,height:1117)])
        XCTAssertNil(below.mainEdgePoint,"no free main edge to press")
        let partial=DockGuardLayout(main:main,others:[CGRect(x:600,y:1117,width:500,height:800)])
        XCTAssertEqual(partial.mainEdgePoint,CGPoint(x:432,y:1116))
    }
}
