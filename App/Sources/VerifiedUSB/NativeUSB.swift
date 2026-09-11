import Foundation
import CLibUSB

public struct USBWriteFailure: Error, CustomStringConvertible {
    public let status: Int32
    public let actual: Int
    public let expected: Int
    public var description: String { "USB transfer status=\(status), actual=\(actual), requested=\(expected)" }
}

/// Each capture worker exclusively owns one instance on its preparation task.
public final class NativeUSB {
    private var context: OpaquePointer?
    private var handle: OpaquePointer?
    private var claimed=false

    private static func checked(_ status: Int32, _ operation: String) throws {
        guard status>=0 else { throw NativeError.invalid("\(operation): \(String(cString:libusb_error_name(status)))") }
    }
    private static func path(_ device: OpaquePointer) throws -> String {
        var ports=[UInt8](repeating:0,count:8)
        let n=libusb_get_port_numbers(device,&ports,Int32(ports.count))
        try checked(n,"USB port path")
        return "\(libusb_get_bus_number(device)):"+ports.prefix(Int(n)).map(String.init).joined(separator:".")
    }
    private static func matching(_ context: OpaquePointer?, _ visit: (OpaquePointer,String) throws -> Void) throws {
        var devices: UnsafeMutablePointer<OpaquePointer?>?
        let count=libusb_get_device_list(context,&devices)
        guard count>=0,let devices else { throw NativeError.invalid("USB enumeration failed") }
        defer { libusb_free_device_list(devices,1) }
        for index in 0..<count {
            guard let device=devices[index] else { continue }
            var descriptor=libusb_device_descriptor()
            try checked(libusb_get_device_descriptor(device,&descriptor),"USB descriptor")
            if descriptor.idVendor==0x34c7 && descriptor.idProduct==0x2114 {
                try visit(device,path(device))
            }
        }
    }
    public static func paths() throws -> [String] {
        var context: OpaquePointer?
        try checked(libusb_init(&context),"USB init")
        defer { libusb_exit(context) }
        var result=[String]()
        try matching(context) { _,path in result.append(path) }
        return result
    }

    public init(path: String, deviceID: UInt32, emit: ([String:Any])->Void) throws {
        try Self.checked(libusb_init(&context),"USB init")
        do {
            var matches=0
            try Self.matching(context) { device,actual in
                if path==actual {
                    matches+=1
                    guard matches==1 else { throw NativeError.invalid("ambiguous USB path") }
                    try Self.checked(libusb_open(device,&handle),"USB open")
                }
            }
            guard matches==1,let handle else { throw NativeError.invalid("confirmed USB path missing: \(path)") }
            try Self.checked(libusb_claim_interface(handle,0),"USB claim")
            claimed=true
            let bytes=try controlRead(0x50,0,4)
            guard bytes.count==4 else { throw NativeError.invalid("short device identity") }
            let actual=bytes.enumerated().reduce(UInt32(0)) { $0 | UInt32($1.element) << (8*$1.offset) }
            guard actual==deviceID else { throw NativeError.invalid("USB device ID differs from confirmed mapping") }
            emit(["event":"identity_verified","device_id":actual,"usb_path":path])
            try Self.checked(libusb_set_interface_alt_setting(handle,0,0),"USB alternate interface")
            for (request,value,length): (UInt8,UInt16,Int) in [(0x40,0,2),(0x50,0,4),(0x51,0,2),(0x52,0,2),
                       (0x49,0,1),(0x41,0,2),(0x41,1,128),(0x41,2,128)] {
                do {
                    let data=try controlRead(request,value,length)
                    emit(["event":"control_in","request":request,"value":value,"actual":data.count])
                } catch { emit(["event":"control_in","request":request,"value":value,"error":String(describing:error)]) }
            }
            for (request,value,data): (UInt8,UInt16,Data) in [(0x83,1,FrameValidation.quantization),
                    (0x81,0,Data([0x80,0x07,0xb0,0x04])),(0x81,0,Data([0x80,0x07,0xb0,0x04]))] {
                var payload=data
                let count=payload.withUnsafeMutableBytes {
                    libusb_control_transfer(handle,0x41,request,value,0,$0.bindMemory(to:UInt8.self).baseAddress,UInt16($0.count),500)
                }
                guard count==data.count else { throw NativeError.invalid("configuration write incomplete: \(count)") }
                emit(["event":"control_out","request":request,"value":value,"actual":count])
            }
            emit(["event":"configuration_settle","seconds":1.0])
            Thread.sleep(forTimeInterval:1)
        } catch { close();throw error }
    }
    private func controlRead(_ request: UInt8,_ value: UInt16,_ length: Int) throws -> Data {
        var data=Data(count:length)
        let count=data.withUnsafeMutableBytes {
            libusb_control_transfer(handle,0xc1,request,value,0,$0.bindMemory(to:UInt8.self).baseAddress,UInt16(length),500)
        }
        try Self.checked(count,"USB control read")
        return Data(data.prefix(Int(count)))
    }
    public func write(_ data: Data) throws -> Int {
        guard let handle,data.count<=Int(Int32.max) else { throw NativeError.invalid("USB write without handle or oversized frame") }
        var actual:Int32=0
        let status=data.withUnsafeBytes {
            libusb_bulk_transfer(handle,1,UnsafeMutablePointer(mutating:$0.bindMemory(to:UInt8.self).baseAddress),Int32(data.count),&actual,5000)
        }
        try FrameValidation.requireComplete(status:status,transferred:Int(actual),expected:data.count)
        return Int(actual)
    }
    public func close() {
        if let handle {
            if claimed { _=libusb_release_interface(handle,0) }
            libusb_close(handle)
        }
        handle=nil;claimed=false
        if let context { libusb_exit(context) };context=nil
    }
    deinit { close() }
}
