import XCTest
import CFrameEncoder
@testable import VerifiedDisplayCore

final class PerformanceOptionsTests: XCTestCase {
    func testArrivalCoalescesAndRemembersNotificationBeforeWait() {
        let arrival=FrameArrival();arrival.publish(1);arrival.publish(2)
        XCTAssertTrue(arrival.wait(after:0,timeout:0))
        XCTAssertTrue(arrival.wait(after:1,timeout:0))
        XCTAssertFalse(arrival.wait(after:2,timeout:0.001))
        arrival.publish(1)
        XCTAssertFalse(arrival.wait(after:2,timeout:0))
        DispatchQueue.global().async { arrival.publish(3) }
        XCTAssertTrue(arrival.wait(after:2,timeout:1))
    }
    func testMetalMatchesExactCPUForBothHistoriesIncludingAlphaAndTileEdges() throws {
        guard MetalTileDiffer.available else { throw XCTSkip("Metal device unavailable") }
        let width=128,height=24,size=width*height*4
        let gpu=try MetalTileDiffer(width:width,height:height)
        let base=Data(repeating:64,count:size)
        for offsets in [[0],[127,128,511,512],[size-1],[4096,5001],[]] {
            var current=base,second=base
            for i in offsets { current[i]=99;second[(i+1024)%size]=33 }
            var expected=[UInt8](repeating:0,count:12)
            for previous in [base,second] {
                _ = current.withUnsafeBytes { c in previous.withUnsafeBytes { p in
                    expected.withUnsafeMutableBufferPointer { m in
                        racer_mark_changed_tiles(c.bindMemory(to:UInt8.self).baseAddress,p.bindMemory(to:UInt8.self).baseAddress,size,128,24,m.baseAddress,12)
                    }
                }}
            }
            XCTAssertEqual(try gpu.changes(current:current,first:base,second:second),expected)
        }
        XCTAssertThrowsError(try gpu.changes(current:Data(),first:base,second:base))
    }
    func testGPUAndCPUWireBytesAndHistorySettleMatch() throws {
        guard MetalTileDiffer.available else { throw XCTSkip("Metal device unavailable") }
        var cpu=try DeltaEncoder(width:64,height:16,options:.init(workers:1))
        var gpu=try DeltaEncoder(width:64,height:16,options:.init(workers:2,damage:.metal))
        var pixels=Data(repeating:64,count:4096)
        for generation in 1...4 {
            pixels[generation*129]=UInt8(generation*40)
            for _ in 0..<4 {
                let a=try cpu.prepare(bgra:pixels,stride:256,generation:generation)
                let b=try gpu.prepare(bgra:pixels,stride:256,generation:generation)
                XCTAssertEqual(a?.data,b?.data);XCTAssertEqual(a?.tiles,b?.tiles)
                if let a,let b {
                    try cpu.complete(a,transferred:a.data.count,succeeded:true)
                    try gpu.complete(b,transferred:b.data.count,succeeded:true)
                }
            }
        }
    }
    func testFullModeStillIdlesAndRequiresExactACK() throws {
        var encoder=try DeltaEncoder(width:64,height:16,options:.init(workers:1,compression:.full))
        var pixels=Data(repeating:64,count:4096)
        for generation in 1...2 {
            pixels[0]=UInt8(generation*70)
            for _ in 0..<2 {
                let f=try XCTUnwrap(encoder.prepare(bgra:pixels,stride:256,generation:generation))
                XCTAssertEqual(f.tiles,[0,1,2,3]);try encoder.complete(f,transferred:f.data.count,succeeded:true)
            }
            XCTAssertNil(try encoder.prepare(bgra:pixels,stride:256,generation:generation))
        }
        encoder.invalidate()
        XCTAssertEqual(try encoder.prepare(bgra:pixels,stride:256)?.tiles.count,4)
    }
}
