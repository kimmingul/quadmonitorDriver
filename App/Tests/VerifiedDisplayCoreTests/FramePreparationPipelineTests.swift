import XCTest
@testable import VerifiedDisplayCore

final class FramePreparationPipelineTests: XCTestCase {
    private func wait(_ pipeline: FramePreparationPipeline) {
        let deadline=Date(timeIntervalSinceNow:2)
        while pipeline.isPreparing && Date()<deadline { Thread.sleep(forTimeInterval:0.001) }
        XCTAssertFalse(pipeline.isPreparing)
    }
    private func snapshot(_ generation: Int) -> EncodingSnapshot {
        EncodingSnapshot(pixels:Data(repeating:UInt8(40+generation),count:4096),stride:256,generation:generation,createdAt:Double(generation))
    }
    func testPredictionCannotAdvanceOriginalAndNeedsExactACK() throws {
        for outcome in ["success","partial","failed","missing"] {
            let pipeline=FramePreparationPipeline()
            var original=try DeltaEncoder(width:64,height:16,options:.init(workers:1,reuseBuffers:true))
            let first=snapshot(1),next=snapshot(2)
            let frame=try XCTUnwrap(original.prepare(bgra:first.pixels,stride:256,generation:1))
            XCTAssertTrue(try pipeline.start(encoder:original,completing:frame,snapshot:{next}))
            wait(pipeline)
            XCTAssertThrowsError(try original.prepare(bgra:next.pixels,stride:256,generation:2))
            if outcome != "missing" {
                let count=outcome == "partial" ? 1 : frame.data.count
                pipeline.acknowledge(frame,transferred:count,succeeded:outcome != "failed")
                try original.complete(frame,transferred:count,succeeded:outcome != "failed")
            }
            let prepared=pipeline.take(generation:2)
            if outcome == "success" {
                let expected=try original.prepare(bgra:next.pixels,stride:256,generation:2)
                XCTAssertEqual(prepared?.frame?.data,expected?.data)
                XCTAssertEqual(prepared?.frame?.tiles.count,4)
            } else { XCTAssertNil(prepared) }
            XCTAssertNil(pipeline.take(generation:2))
        }
    }
    func testBusyDiscardDoesNotBlockOrQueueAndStaleGenerationCannotBeAdopted() throws {
        let pipeline=FramePreparationPipeline(),gate=DispatchSemaphore(value:0)
        var encoder=try DeltaEncoder(width:64,height:16)
        let next=snapshot(2)
        let frame=try XCTUnwrap(encoder.prepare(bgra:snapshot(1).pixels,stride:256,generation:1))
        XCTAssertTrue(try pipeline.start(encoder:encoder,completing:frame,snapshot:{
            _ = gate.wait(timeout:.now()+2); return next
        }))
        pipeline.acknowledge(frame,transferred:frame.data.count,succeeded:true)
        XCTAssertNil(pipeline.take(generation:2)) // still busy: immediate fallback
        XCTAssertTrue(pipeline.isPreparing)
        XCTAssertFalse(try pipeline.start(encoder:encoder,completing:frame,snapshot:{next}))
        gate.signal();wait(pipeline)
        XCTAssertNil(pipeline.take(generation:2)) // old result cannot reappear
        XCTAssertTrue(try pipeline.start(encoder:encoder,completing:frame,snapshot:{next}))
        pipeline.acknowledge(frame,transferred:frame.data.count,succeeded:true);wait(pipeline)
        XCTAssertNil(pipeline.take(generation:3)) // newest snapshot wins
        pipeline.discard()
    }
    func testPipelineMatchesSerialBothHistoriesThroughMotionAndSettling() throws {
        let pipeline=FramePreparationPipeline()
        var actual=try DeltaEncoder(width:64,height:16,options:.init(workers:2,reuseBuffers:true,adaptiveWorkers:true))
        var expected=try DeltaEncoder(width:64,height:16,options:.init(workers:1))
        let sequence=[1,1,2,3,3,3,4,4,4]
        var cached: PipelinedPreparation?
        for (index,generation) in sequence.enumerated() {
            let pixels=snapshot(generation)
            let a: PreparedFrame?
            if let c=cached { actual=c.encoder;a=c.frame } else { a=try actual.prepare(bgra:pixels.pixels,stride:256,generation:generation) }
            let b=try expected.prepare(bgra:pixels.pixels,stride:256,generation:generation)
            XCTAssertEqual(a?.data,b?.data);XCTAssertEqual(a?.tiles,b?.tiles)
            cached=nil
            if let a,let b {
                if index+1<sequence.count {
                    let next=snapshot(sequence[index+1])
                    XCTAssertTrue(try pipeline.start(encoder:actual,completing:a,snapshot:{next}))
                }
                try actual.complete(a,transferred:a.data.count,succeeded:true)
                try expected.complete(b,transferred:b.data.count,succeeded:true)
                pipeline.acknowledge(a,transferred:a.data.count,succeeded:true);wait(pipeline)
                if index+1<sequence.count { cached=pipeline.take(generation:sequence[index+1]);XCTAssertNotNil(cached) }
            }
        }
    }
    func testPreparationErrorAndShutdownDiscardResult() throws {
        let pipeline=FramePreparationPipeline()
        var encoder=try DeltaEncoder(width:64,height:16)
        let frame=try XCTUnwrap(encoder.prepare(bgra:snapshot(1).pixels,stride:256))
        XCTAssertTrue(try pipeline.start(encoder:encoder,completing:frame,snapshot:{ throw FrameError.invalidPixels }))
        pipeline.acknowledge(frame,transferred:frame.data.count,succeeded:true);wait(pipeline)
        XCTAssertNil(pipeline.take(generation:2))
        let next=snapshot(2)
        XCTAssertTrue(try pipeline.start(encoder:encoder,completing:frame,snapshot:{next}))
        pipeline.discard();wait(pipeline)
        pipeline.acknowledge(frame,transferred:frame.data.count,succeeded:true)
        XCTAssertNil(pipeline.take(generation:2))
    }
}
