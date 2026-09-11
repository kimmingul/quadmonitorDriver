import Foundation
#if canImport(CIOKitUSB)
import CIOKitUSB
#endif

enum IOKitUSBTransportError: Error, LocalizedError {
    case unsupportedPlatform
    case openFailed(String, Int32)
    case noMatchingDevices
    case notConnected
    case writeFailed(Int32)
    case readFailed(Int32)

    var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "IOKit USB backend is not available on this build"
        case .openFailed(let msg, let rc):
            return "IOKit open failed: \(msg) (rc=0x\(String(format: "%X", UInt32(bitPattern: rc))))"
        case .noMatchingDevices:
            return "no IOKit USB devices matched provided VID/PID"
        case .notConnected:
            return "IOKit transport is not connected"
        case .writeFailed(let rc):
            return "IOKit bulk write failed rc=0x\(String(format: "%X", UInt32(bitPattern: rc)))"
        case .readFailed(let rc):
            return "IOKit control IN failed rc=0x\(String(format: "%X", UInt32(bitPattern: rc)))"
        }
    }
}

/// IOKit-backed USB transport. Uses IOUSBLib via the IOCFPlugIn interface
/// (the same path as the original RacerUSB.app) to gain access to host-side
/// pipe management primitives — `AbortPipe` and `ResetPipe` — that libusb
/// does not expose. These are required to recover the bulk OUT pipe after
/// the firmware's 16-packet receive ring fills (see HANDOFF.md §6 issue 1).
actor IOKitUSBTransport: USBTransport {
    private let logger: Logger
    private let vendorID: UInt16
    private let productID: UInt16

    #if canImport(CIOKitUSB)
    private var devices: [OpaquePointer] = []
    #endif

    init(logger: Logger, vendorID: UInt16, productID: UInt16) {
        self.logger = logger
        self.vendorID = vendorID
        self.productID = productID
    }

    func connect() async throws {
        #if canImport(CIOKitUSB)
        let maxDevices = 4
        var slots = [OpaquePointer?](repeating: nil, count: maxDevices)
        var errBuf = [CChar](repeating: 0, count: 256)

        let count = slots.withUnsafeMutableBufferPointer { slotPtr in
            errBuf.withUnsafeMutableBufferPointer { errPtr in
                iokit_usb_open_matching(
                    vendorID,
                    productID,
                    UnsafeMutablePointer<OpaquePointer?>(slotPtr.baseAddress),
                    Int32(maxDevices),
                    errPtr.baseAddress,
                    Int32(errPtr.count)
                )
            }
        }

        if count <= 0 {
            let msg = String(cString: errBuf)
            throw IOKitUSBTransportError.openFailed(msg.isEmpty ? "no devices" : msg, count)
        }

        devices = slots.prefix(Int(count)).compactMap { $0 }
        for d in devices {
            let bus = iokit_usb_bus_number(d)
            let addr = iokit_usb_device_address(d)
            do {
                try runUnlockSequence(device: d)
                logger.info("IOKit opened+unlocked device bus=\(bus) addr=\(addr)")
            } catch {
                logger.warning("IOKit unlock failed bus=\(bus) addr=\(addr): \(error.localizedDescription)")
            }
        }
        logger.info("IOKit connected to \(devices.count) matching device(s)")
        #else
        throw IOKitUSBTransportError.unsupportedPlatform
        #endif
    }

    func write(_ bytes: Data) async throws {
        #if canImport(CIOKitUSB)
        guard !devices.isEmpty else { throw IOKitUSBTransportError.notConnected }
        for (i, _) in devices.enumerated() {
            try await writeRaw(deviceIndex: i, bytes: bytes)
        }
        #else
        throw IOKitUSBTransportError.unsupportedPlatform
        #endif
    }

    func read(maxBytes: Int) async throws -> Data {
        return Data([ProtocolCommand.heartbeat.rawValue, 0, 0])
    }

    func disconnect() async {
        #if canImport(CIOKitUSB)
        for d in devices { iokit_usb_close(d) }
        devices.removeAll(keepingCapacity: false)
        #endif
    }

    func deviceCount() async -> Int {
        #if canImport(CIOKitUSB)
        return devices.count
        #else
        return 0
        #endif
    }

    /// Raw device handle as bit-pattern (Sendable-friendly) for use in
    /// non-actor contexts (e.g., SCStream callback on libdispatch's
    /// CMCapture queue). Caller reconstructs OpaquePointer via
    /// `OpaquePointer(bitPattern:)`. Caller must guarantee the transport
    /// stays connected for the pointer's lifetime.
    func rawDevicePointerBits(at index: Int) -> UInt {
        #if canImport(CIOKitUSB)
        guard index >= 0, index < devices.count else { return 0 }
        return UInt(bitPattern: Int(bitPattern: UnsafeRawPointer(devices[index])))
        #else
        return 0
        #endif
    }

    func writeRaw(deviceIndex: Int, bytes: Data) async throws {
        #if canImport(CIOKitUSB)
        guard deviceIndex >= 0, deviceIndex < devices.count else {
            throw IOKitUSBTransportError.notConnected
        }
        let dev = devices[deviceIndex]
        let bus = iokit_usb_bus_number(dev)
        let addr = iokit_usb_device_address(dev)

        var transferred: UInt32 = 0
        let rc: Int32 = bytes.withUnsafeBytes { raw -> Int32 in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return Int32(bitPattern: 0xE00002BD) // kIOReturnBadArgument
            }
            return iokit_usb_bulk_write(
                dev,
                /* pipe_ref */ 1,
                base,
                UInt32(bytes.count),
                /* no_data_timeout_ms */ 500,
                /* completion_timeout_ms */ 500,
                /* max_retries */ 2,
                &transferred
            )
        }
        if rc != 0 {
            logger.warning(
                "IOKit bulk write FAILED bus=\(bus) addr=\(addr) rc=0x\(String(format: "%X", UInt32(bitPattern: rc))) sent=\(transferred)/\(bytes.count)"
            )
            throw IOKitUSBTransportError.writeFailed(rc)
        }
        logger.info("IOKit bulk write OK bus=\(bus) addr=\(addr) sent=\(transferred)/\(bytes.count)")
        #else
        throw IOKitUSBTransportError.unsupportedPlatform
        #endif
    }

    /// Issue a single ReadPipeTO on `pipe_ref` (default 1 = the bulk
    /// endpoint). Mirrors UsbDisplay fn_100015c64's recovery sequence
    /// (SetPipePolicy + sleep(0) + ReadPipe(pipeRef=1)) when WritePipeTO
    /// returns 0xE000_404F. The endpoint is OUT-only per the device
    /// descriptor, so the kernel is expected to reject this — non-zero rc
    /// is informational. Returns (rc, transferred). Surfaced standalone so
    /// the orchestrator can probe it before/after bulk writes.
    func bulkReadProbe(deviceIndex: Int, pipeRef: UInt8 = 1, size: Int = 64, timeoutMs: UInt32 = 500) async -> (rc: Int32, transferred: UInt32) {
        #if canImport(CIOKitUSB)
        guard deviceIndex >= 0, deviceIndex < devices.count else { return (-1, 0) }
        let dev = devices[deviceIndex]
        var buf = [UInt8](repeating: 0, count: size)
        var transferred: UInt32 = 0
        let rc: Int32 = buf.withUnsafeMutableBufferPointer { ptr in
            iokit_usb_bulk_read(dev, pipeRef, ptr.baseAddress, UInt32(size), timeoutMs, timeoutMs, &transferred)
        }
        return (rc, transferred)
        #else
        return (-1, 0)
        #endif
    }

    func vendorOut(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, payload: Data) async throws -> Bool {
        #if canImport(CIOKitUSB)
        guard deviceIndex >= 0, deviceIndex < devices.count else {
            throw IOKitUSBTransportError.notConnected
        }
        let rc: Int32 = payload.withUnsafeBytes { raw in
            iokit_usb_vendor_out(
                devices[deviceIndex],
                bRequest,
                wValue,
                raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt16(payload.count),
                500
            )
        }
        return rc == 0
        #else
        throw IOKitUSBTransportError.unsupportedPlatform
        #endif
    }

    func clearHalt(deviceIndex: Int) async throws {
        #if canImport(CIOKitUSB)
        guard deviceIndex >= 0, deviceIndex < devices.count else {
            throw IOKitUSBTransportError.notConnected
        }
        // Use ResetPipe — host-side pipe state reset, the same call the
        // original app uses in its bulk-write recovery loop.
        let rc = iokit_usb_reset_pipe(devices[deviceIndex], 1)
        if rc != 0 {
            logger.info("IOKit reset_pipe rc=0x\(String(format: "%X", UInt32(bitPattern: rc)))")
        }
        #else
        throw IOKitUSBTransportError.unsupportedPlatform
        #endif
    }

    func vendorIn(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, wLength: UInt16) async throws -> Data? {
        #if canImport(CIOKitUSB)
        guard deviceIndex >= 0, deviceIndex < devices.count else {
            throw IOKitUSBTransportError.notConnected
        }
        var buffer = [UInt8](repeating: 0, count: Int(wLength))
        let rc: Int32 = buffer.withUnsafeMutableBufferPointer { ptr in
            iokit_usb_vendor_in(
                devices[deviceIndex],
                bRequest,
                wValue,
                ptr.baseAddress,
                wLength,
                500
            )
        }
        if rc < 0 { return nil }
        return Data(buffer.prefix(Int(rc)))
        #else
        throw IOKitUSBTransportError.unsupportedPlatform
        #endif
    }

    #if canImport(CIOKitUSB)
    /// Same vendor-control sequence as LibUSBTransport.runUnlockSequence —
    /// IN reads, then DQT once, SetResolution(0x81) twice (matches the
    /// captured lldb trace of the original app exactly).
    private func runUnlockSequence(device: OpaquePointer) throws {
        let initReads: [(UInt8, UInt16, UInt16)] = [
            (0x40, 0,   2),
            (0x50, 0,   4),
            (0x51, 0,   2),
            (0x52, 0,   2),
            (0x49, 0,   1),
            (0x41, 0,   2),
            (0x41, 1, 128),
            (0x41, 2, 128),
        ]
        for (req, value, length) in initReads {
            var buf = [UInt8](repeating: 0, count: Int(length))
            _ = buf.withUnsafeMutableBufferPointer { ptr in
                iokit_usb_vendor_in(device, req, value, ptr.baseAddress, length, 500)
            }
        }

        // DQT (138B)
        let dqt = LibUSBTransport.bulkUnlockDQT
        let dqtRc = dqt.withUnsafeBufferPointer { ptr in
            iokit_usb_vendor_out(device, 0x83, 1, ptr.baseAddress, UInt16(dqt.count), 500)
        }
        if dqtRc != 0 {
            throw IOKitUSBTransportError.writeFailed(dqtRc)
        }

        // SetResolution 1920x1200 — twice, matching the trace.
        let resolution: [UInt8] = [0x80, 0x07, 0xb0, 0x04]
        for _ in 0..<2 {
            let rc = resolution.withUnsafeBufferPointer { ptr in
                iokit_usb_vendor_out(device, 0x81, 0, ptr.baseAddress, UInt16(resolution.count), 500)
            }
            if rc != 0 {
                throw IOKitUSBTransportError.writeFailed(rc)
            }
        }

        // Hypothesis I (2026-04-26 session #3): UsbDisplay launch trace shows
        // a *second* vendor-IN read pass per device after the first unlock.
        // The second pass differs from the first: bReq=0x49 (heartbeat) is
        // dropped, and bReq=0x65 reads (wValue=0/1/2) are added — never tried
        // before. Suspected to flip the device into a higher-throughput mode.
        if ProcessInfo.processInfo.environment["IOKIT_SECOND_UNLOCK"] == "1" {
            let secondPassReads: [(UInt8, UInt16, UInt16)] = [
                (0x40, 0,   2),
                (0x50, 0,   4),
                (0x51, 0,   2),
                (0x52, 0,   2),
                (0x65, 0,   2),    // new — never observed in our prior unlock
                (0x65, 1, 128),
                (0x65, 2, 128),
            ]
            for (req, value, length) in secondPassReads {
                var b = [UInt8](repeating: 0, count: Int(length))
                _ = b.withUnsafeMutableBufferPointer { ptr in
                    iokit_usb_vendor_in(device, req, value, ptr.baseAddress, length, 500)
                }
            }
        }
    }
    #endif
}
