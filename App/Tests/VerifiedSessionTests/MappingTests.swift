import XCTest
@testable import VerifiedSession

final class MappingTests: XCTestCase {
    let rows=[PanelMapping(role:"right",usbPath:"0:1.1",deviceID:1),PanelMapping(role:"left",usbPath:"0:1.2",deviceID:2),PanelMapping(role:"top",usbPath:"0:1.4",deviceID:3)]
    func testSelectionsAndIdentityAmbiguity() throws {
        for roles in [["right"],["left","top"],["right","left","top"]] {
            XCTAssertEqual(try PanelMapping.select(rows,roles:roles).count,roles.count)
        }
        XCTAssertThrowsError(try PanelMapping.select(rows,roles:["right","right"]))
        var bad=rows;bad[1].deviceID=1
        XCTAssertThrowsError(try PanelMapping.select(bad,roles:["right"]))
        XCTAssertEqual(PanelMapping.missing(rows,paths:["0:1.1","0:1.2","0:1.2"]),["0:1.2","0:1.4"])
    }
    func testBindingRejectsMirroringAndDuplicateDisplayIDs() throws {
        let mapping=try PanelMapping.select(rows,roles:["right","left"])
        var displays:[[String:Any]]=[["role":"right","display_id":11,"mirrored":false,"width":1920,"height":1200],
                                     ["role":"left","display_id":12,"mirrored":false,"width":1920,"height":1200]]
        XCTAssertEqual(try PanelMapping.bind(mapping,displays:displays),["right":11,"left":12])
        displays[1]["display_id"]=11
        XCTAssertThrowsError(try PanelMapping.bind(mapping,displays:displays))
        displays[1]["display_id"]=12;displays[0]["mirrored"]=true
        XCTAssertThrowsError(try PanelMapping.bind(mapping,displays:displays))
    }
    func testOptionsRejectInvalidDangerousCombinations() throws {
        let path=URL(fileURLWithPath:"/tmp/Quad Monitor.app/Contents/Helpers/VerifiedSession")
        for args in [["--send"],["--continuous"],["--fps","61"],["--panels",""],["--unknown"],["--fps","30","--fps","60"]] {
            XCTAssertThrowsError(try SessionOptions(args,executable:path))
        }
        let options=try SessionOptions(["--run","--send","--continuous","--panels","left,top"],executable:path)
        XCTAssertEqual(options.seconds,0);XCTAssertEqual(options.fps,60)
        XCTAssertEqual(options.host.path,"/tmp/Quad Monitor.app/Contents/Helpers/VerifiedDesktopHost")
    }
}
