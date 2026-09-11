import XCTest
@testable import VerifiedDisplayCore

final class AlgorithmOptionsTests: XCTestCase {
    func testOldPreferencesKeepAllNewOptionsOffAndRoundTrip() throws {
        let old = Data(#"{"workers":1,"scheduling":"arrival","damage":"cpu","compression":"delta","queueDepth":3}"#.utf8)
        let options = try JSONDecoder().decode(PerformanceOptions.self, from: old)
        XCTAssertEqual(options, PerformanceOptions(workers:1,scheduling:.arrival))
        let new = PerformanceOptions(workers:8,reuseBuffers:true,adaptiveWorkers:true,overlapPreparation:true)
        XCTAssertEqual(try JSONDecoder().decode(PerformanceOptions.self,from:JSONEncoder().encode(new)),new)
    }

    func testOverlapSkipsCursorAndRespectsOffSwitch() {
        let on=PerformanceOptions(overlapPreparation:true)
        for count in [0,1,8,511] { XCTAssertFalse(on.shouldOverlap(changedTiles:count)) }
        for count in [512,9000] { XCTAssertTrue(on.shouldOverlap(changedTiles:count)) }
        XCTAssertFalse(PerformanceOptions().shouldOverlap(changedTiles:9000))
    }

    func testAdaptiveThresholdsRespectEveryPanelBudget() {
        for ceiling in [1,2,4,8] {
            let options = PerformanceOptions(workers:ceiling,adaptiveWorkers:true)
            for (tiles,expected) in [(0,1),(511,1),(512,2),(1023,2),(1024,4),(2047,4),(2048,8),(4096,8),(9000,8)] {
                XCTAssertEqual(options.workers(forChangedTiles:tiles),min(ceiling,expected))
            }
        }
    }

    func testPoolReuseAndRetainedFramesAcrossEncoderCopiesAndFailure() throws {
        var encoder = try DeltaEncoder(width:64,height:16,options:.init(workers:1,reuseBuffers:true))
        var reference = try DeltaEncoder(width:64,height:16,options:.init(workers:1))
        var retained: [(PreparedFrame,Data)] = []
        var reused = 0
        for i in 0..<30 {
            let pixels = Data(repeating:UInt8(i+40),count:4096)
            let frame = try XCTUnwrap(encoder.prepare(bgra:pixels,stride:256,generation:i))
            let expected = try XCTUnwrap(reference.prepare(bgra:pixels,stride:256,generation:i))
            XCTAssertEqual(frame.data,expected.data)
            if encoder.lastPreparation.outputBufferReused { reused += 1 }
            if i % 4 == 0 { retained.append((frame,Data(Array(frame.data)))) }
            var copy = encoder
            try copy.complete(frame,transferred:frame.data.count,succeeded:true)
            let other = try copy.prepare(bgra:Data(repeating:199,count:4096),stride:256)
            XCTAssertNotNil(other)
            let success = i % 7 != 0
            try encoder.complete(frame,transferred:success ? frame.data.count : 1,succeeded:success)
            try reference.complete(expected,transferred:success ? expected.data.count : 1,succeeded:success)
            for (old,bytes) in retained { XCTAssertEqual(old.data,bytes) }
        }
        XCTAssertGreaterThan(reused,10)
    }

    func testConcurrentEncoderCopiesShareOnlyLockedPoolAndMetalStorage() throws {
        guard MetalTileDiffer.available else { throw XCTSkip("Metal unavailable") }
        var setup=try DeltaEncoder(width:64,height:16,options:.init(workers:2,damage:.metal,reuseBuffers:true))
        let base=Data(repeating:64,count:4096)
        for _ in 0..<2 {
            let frame=try XCTUnwrap(setup.prepare(bgra:base,stride:256))
            try setup.complete(frame,transferred:frame.data.count,succeeded:true)
        }
        let initial=setup
        DispatchQueue.concurrentPerform(iterations:8) { index in
            do {
                var encoder=initial
                var oracle=try DeltaEncoder(width:64,height:16,options:.init(workers:1))
                for _ in 0..<2 {
                    let frame=try XCTUnwrap(oracle.prepare(bgra:base,stride:256))
                    try oracle.complete(frame,transferred:frame.data.count,succeeded:true)
                }
                for generation in 1...4 {
                    var pixels=base;pixels[index*128+generation]=UInt8(100+index)
                    let a=try XCTUnwrap(encoder.prepare(bgra:pixels,stride:256,generation:generation))
                    let b=try XCTUnwrap(oracle.prepare(bgra:pixels,stride:256,generation:generation))
                    XCTAssertEqual(a.data,b.data)
                    try encoder.complete(a,transferred:a.data.count,succeeded:true)
                    try oracle.complete(b,transferred:b.data.count,succeeded:true)
                }
            } catch { XCTFail("Concurrent encoding failed: \(error)") }
        }
    }

    func testAdaptiveAndPooledWireMatchesAcrossLargeAndSmallUpdates() throws {
        let width=1024,height=1024
        var reference = try DeltaEncoder(width:width,height:height,options:.init(workers:1))
        var candidate = try DeltaEncoder(width:width,height:height,options:.init(workers:8,reuseBuffers:true,adaptiveWorkers:true))
        var pixels=Data(repeating:99,count:width*height*4)
        for generation in 0..<8 {
            if generation % 2 == 0 { pixels=Data(repeating:UInt8(99+generation),count:pixels.count) }
            else { pixels[generation*1024]=3 }
            for _ in 0..<3 {
                let a=try reference.prepare(bgra:pixels,stride:width*4,generation:generation)
                let b=try candidate.prepare(bgra:pixels,stride:width*4,generation:generation)
                XCTAssertEqual(a?.data,b?.data);XCTAssertEqual(a?.tiles,b?.tiles)
                if let a,let b {
                    try reference.complete(a,transferred:a.data.count,succeeded:true)
                    try candidate.complete(b,transferred:b.data.count,succeeded:true)
                }
            }
        }
    }
}
