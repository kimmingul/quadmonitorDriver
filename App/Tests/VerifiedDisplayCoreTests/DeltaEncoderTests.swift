import XCTest
@testable import VerifiedDisplayCore

final class DeltaEncoderTests: XCTestCase {
    private func pixels(_ value: UInt8 = 64) -> Data { Data(repeating: value, count: 64*16*4) }

    private func send(_ pixels: Data, through encoder: inout DeltaEncoder) throws -> [Int]? {
        guard let frame = try encoder.prepare(bgra: pixels, stride: 256) else { return nil }
        try encoder.complete(frame, transferred: frame.data.count, succeeded: true)
        return frame.tiles
    }

    func testOriginalTwoHistorySequence() throws {
        var encoder = try DeltaEncoder(width: 64, height: 16)
        let first = pixels()
        XCTAssertEqual(try send(first, through: &encoder), [0,1,2,3])
        XCTAssertEqual(try send(first, through: &encoder), [0,1,2,3])
        XCTAssertNil(try send(first, through: &encoder))
        XCTAssertNil(try send(first, through: &encoder))
        var changed = first; changed[0] = 200
        XCTAssertEqual(try send(changed, through: &encoder), [0])
        XCTAssertEqual(try send(changed, through: &encoder), [0])
        XCTAssertNil(try send(changed, through: &encoder))
    }

    func testPartialOrFailedWriteRequiresTwoKeyframes() throws {
        for success in [true, false] {
            var encoder = try DeltaEncoder(width: 64, height: 16)
            _ = try send(pixels(), through: &encoder)
            _ = try send(pixels(), through: &encoder)
            var changed = pixels(); changed[0] = 200
            let frame = try XCTUnwrap(encoder.prepare(bgra: changed, stride: 256))
            try encoder.complete(frame, transferred: success ? 16 : frame.data.count, succeeded: success)
            XCTAssertEqual(try send(changed, through: &encoder), [0,1,2,3])
            XCTAssertEqual(try send(changed, through: &encoder), [0,1,2,3])
            XCTAssertNil(try send(changed, through: &encoder))
        }
    }

    func testPendingFrameIsImmutableAndStaleCompletionCannotCommit() throws {
        var encoder = try DeltaEncoder(width: 64, height: 16)
        var input = pixels()
        let frame = try XCTUnwrap(encoder.prepare(bgra: input, stride: 256))
        let saved = frame.data
        input[0] = 200
        XCTAssertThrowsError(try encoder.prepare(bgra: input, stride: 256))
        encoder.invalidate()
        let next = try XCTUnwrap(encoder.prepare(bgra: input, stride: 256))
        XCTAssertThrowsError(try encoder.complete(frame, transferred: saved.count, succeeded: true))
        XCTAssertEqual(frame.data, saved)
        try encoder.complete(next, transferred: next.data.count, succeeded: true)
        XCTAssertEqual(try send(input, through: &encoder), [0,1,2,3])
    }

    func testRejectsTruncatedAndInvalidDimensions() throws {
        XCTAssertThrowsError(try DeltaEncoder(width: 31, height: 16))
        var encoder = try DeltaEncoder(width: 64, height: 16)
        XCTAssertThrowsError(try encoder.prepare(bgra: Data(count: 4095), stride: 256))
        XCTAssertThrowsError(try encoder.prepare(bgra: pixels(), stride: 255))
    }

    func testStridePaddingDoesNotTriggerChanges() throws {
        var encoder = try DeltaEncoder(width: 64, height: 16)
        _ = try send(pixels(), through: &encoder)
        _ = try send(pixels(), through: &encoder)
        var padded = Data(repeating: 99, count: 272*16)
        for row in 0..<16 { padded.replaceSubrange(row*272..<row*272+256, with: pixels()[0..<256]) }
        XCTAssertNil(try encoder.prepare(bgra: padded, stride: 272))
    }

    func testGenerationsMatchUncachedWireBytesAcrossBothHistoriesAndInvalidation() throws {
        var cached = try DeltaEncoder(width: 64, height: 16)
        var oracle = try DeltaEncoder(width: 64, height: 16)
        var input = pixels()
        for generation in 1...5 {
            input[(generation*129)%input.count] = UInt8(generation*30)
            for repeatIndex in 0..<5 {
                let expected = try oracle.prepare(bgra: input, stride: 256)
                let actual = try cached.prepare(bgra: input, stride: 256, generation: generation)
                XCTAssertEqual(actual?.data, expected?.data)
                XCTAssertEqual(actual?.tiles, expected?.tiles)
                if let actual, let expected {
                    // Exercise a short write after both histories have been populated.
                    let success = !(generation == 3 && repeatIndex == 0)
                    try cached.complete(actual, transferred: success ? actual.data.count : 1, succeeded: true)
                    try oracle.complete(expected, transferred: success ? expected.data.count : 1, succeeded: true)
                }
            }
        }
        XCTAssertTrue(cached.lastPreparation.reusedSettledGeneration)
        cached.invalidate()
        XCTAssertEqual(try cached.prepare(bgra: input, stride: 256, generation: 5)?.tiles, [0,1,2,3])
    }

    func testSharedPackedSnapshotSurvivesCallerMutationAndCacheStillValidatesInput() throws {
        var encoder = try DeltaEncoder(width: 64, height: 16)
        var input = pixels()
        let frame = try XCTUnwrap(encoder.prepare(bgra: input, stride: 256, generation: 1))
        XCTAssertEqual(encoder.lastPreparation.copiedBytes, 0)
        input[0] = 200
        try encoder.complete(frame, transferred: frame.data.count, succeeded: true)
        let second = try XCTUnwrap(encoder.prepare(bgra: pixels(), stride: 256, generation: 1))
        try encoder.complete(second, transferred: second.data.count, succeeded: true)
        XCTAssertNil(try encoder.prepare(bgra: pixels(), stride: 256, generation: 1))
        XCTAssertThrowsError(try encoder.prepare(bgra: Data(), stride: 256, generation: 1))
        XCTAssertEqual(try encoder.prepare(bgra: input, stride: 256, generation: 2)?.tiles, [0])
    }
}
