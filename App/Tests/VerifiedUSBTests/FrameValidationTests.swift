import XCTest
import VerifiedDisplayCore
@testable import VerifiedUSB

final class FrameValidationTests: XCTestCase {
    func testNativeValidatorRejectsEveryTruncationAndValidatesEncoderOutput() throws {
        var encoder=try DeltaEncoder(width:64,height:16)
        let frame=try XCTUnwrap(encoder.prepare(bgra:Data(repeating:64,count:64*16*4),stride:256))
        var validator=FrameValidation()
        XCTAssertEqual(try validator.validate(frame.data,keyframe:true,width:64,height:16),4)
        for end in 0..<frame.data.count {
            XCTAssertThrowsError(try validator.validate(Data(frame.data.prefix(end)),keyframe:true,width:64,height:16))
        }
        var corrupt=frame.data;corrupt[0]=0
        XCTAssertThrowsError(try validator.validate(corrupt,keyframe:true,width:64,height:16))
    }
    func testOnlyExactSuccessfulWriteCompletes() throws {
        try FrameValidation.requireComplete(status:0,transferred:129,expected:129)
        for (status,actual) in [(Int32(0),128),(Int32(-7),129),(Int32(-4),0),(Int32(0),130)] {
            XCTAssertThrowsError(try FrameValidation.requireComplete(status:status,transferred:actual,expected:129))
        }
    }
}
