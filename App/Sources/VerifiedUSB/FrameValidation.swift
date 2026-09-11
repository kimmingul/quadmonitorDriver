import Foundation
import CFrameEncoder

public enum NativeError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message):return message } }
}

public struct FrameValidation {
    private var positions: [UInt16]
    public init() { positions=Array(repeating:0,count:9000) }
    public mutating func validate(_ data: Data, keyframe: Bool, width: UInt32 = 1920, height: UInt32 = 1200) throws -> Int {
        let count=data.withUnsafeBytes { bytes in
            positions.withUnsafeMutableBufferPointer { out in
                racer_validate_frame(bytes.bindMemory(to:UInt8.self).baseAddress,data.count,width,height,
                                     keyframe ? 1 : 0,out.baseAddress,out.count)
            }
        }
        guard count>=0 else { throw NativeError.invalid("invalid tile container or JPEG entropy") }
        return count
    }
    public static var quantization: Data {
        var data=Data(count:138)
        let count=data.withUnsafeMutableBytes { racer_configuration_quantization($0.bindMemory(to:UInt8.self).baseAddress,$0.count) }
        precondition(count==138)
        return data
    }
    public static func requireComplete(status: Int32, transferred: Int, expected: Int) throws {
        guard status==0,transferred==expected else {
            throw USBWriteFailure(status:status,actual:transferred,expected:expected)
        }
    }
}
