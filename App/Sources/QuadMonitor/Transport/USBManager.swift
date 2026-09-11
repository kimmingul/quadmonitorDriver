import Foundation
import IOSurface

/// Thread-safe wrapper for IOSurfaceRef. IOSurface is reference-counted and
/// the kernel mediates concurrent locks, so passing the ref across actor
/// boundaries is safe in practice — Sendable annotation is just to satisfy
/// the strict-concurrency checker.
public struct SendableSurface: @unchecked Sendable {
    public let ref: IOSurfaceRef
    public init(_ ref: IOSurfaceRef) { self.ref = ref }
}

actor USBManager {
    private let transport: USBTransport
    private let logger: Logger
    private let traceRecorder: ProtocolTraceRecorder
    private var heartbeatPoller: LibUSBHeartbeatPoller?

    init(transport: USBTransport, logger: Logger, traceRecorder: ProtocolTraceRecorder) {
        self.transport = transport
        self.logger = logger
        self.traceRecorder = traceRecorder
    }

    func connect() async throws {
        try await transport.connect()
        logger.info("USB transport connected")
    }

    func initializeDevice() async throws {
        let packet = CommandPacket(command: .initialize, payload: Data([0x03, 0x02]))
        let bytes = packet.serialize()
        await traceRecorder.record(direction: "TX", packet: bytes)
        try await transport.write(bytes)
        logger.info("Initialization packet sent")
    }

    func setDisplayMode(displayIndex: UInt8, mode: DisplayMode) async throws {
        let payload = mode.toPayload(displayIndex: displayIndex)
        let packet = CommandPacket(command: .setDisplayMode, payload: payload)
        let bytes = packet.serialize()
        await traceRecorder.record(direction: "TX", packet: bytes)
        try await transport.write(bytes)
    }

    func sendFrame(_ frame: DeviceFrame) async throws {
        var payload = Data([frame.displayIndex])
        payload.append(frame.encodedBytes)
        let packet = CommandPacket(command: .startStream, payload: payload)
        let bytes = packet.serialize()
        await traceRecorder.record(direction: "TX", packet: bytes)
        try await transport.write(bytes)
    }

    func heartbeat() async throws {
        let packet = CommandPacket(command: .heartbeat, payload: Data())
        let bytes = packet.serialize()
        await traceRecorder.record(direction: "TX", packet: bytes)
        try await transport.write(bytes)
    }

    func sendRaw(_ bytes: Data) async throws {
        await traceRecorder.record(direction: "TX", packet: bytes)
        try await transport.write(bytes)
    }

    func sendRawToDevice(index: Int, bytes: Data) async throws {
        await traceRecorder.record(direction: "TX[\(index)]", packet: bytes.prefix(32))
        try await transport.writeRaw(deviceIndex: index, bytes: bytes)
    }

    /// Surface-backed write — only available on IOUSBHostTransport. Returns
    /// false if the current transport doesn't support the surface path, in
    /// which case the caller can fall back to sendRawToDevice. Tests §17.4:
    /// NSMutableData(bytesNoCopy: IOSurface base) vs anonymous heap copy.
    func sendRawSurfaceToDevice(index: Int, surface: SendableSurface, size: Int) async throws -> Bool {
        guard let iousb = transport as? IOUSBHostTransport else { return false }
        await traceRecorder.record(direction: "TX[\(index)]", packet: Data([0xF1, 0x06])) // marker
        try await iousb.writeRawSurface(deviceIndex: index, surface: surface.ref, size: size)
        return true
    }

    /// Hypothesis Q' — stream one frame to ALL devices concurrently (libusb async)
    /// for `seconds`. Returns false when the transport isn't libusb. Tests whether
    /// concurrent sibling bulk-OUT is what drains the firmware ring.
    func streamAllDevicesAsync(frame: [UInt8], seconds: Int) async -> Bool {
        guard let libusb = transport as? LibUSBTransport else { return false }
        await libusb.streamAllDevicesAsync(frame: frame, seconds: seconds)
        return true
    }

    /// Bit-pattern of IOKit raw device handle (Sendable). Reconstruct via
    /// `OpaquePointer(bitPattern: rc)`. 0 = no device / wrong transport.
    func rawIOKitDevicePointerBits(at index: Int) async -> UInt {
        if let iokit = transport as? IOKitUSBTransport {
            return await iokit.rawDevicePointerBits(at: index)
        }
        return 0
    }

    /// IOKit-only ReadPipe probe — mirrors UsbDisplay's recovery sequence
    /// from fn_100015c64. Returns nil when transport isn't IOKit. Result
    /// `(rc, transferred)` lets the caller log the kernel's response.
    func bulkReadProbe(index: Int, pipeRef: UInt8 = 1, size: Int = 64) async -> (rc: Int32, transferred: UInt32)? {
        guard let iokit = transport as? IOKitUSBTransport else { return nil }
        await traceRecorder.record(direction: "RD-PROBE[\(index)]", packet: Data([pipeRef, UInt8(size & 0xFF)]))
        return await iokit.bulkReadProbe(deviceIndex: index, pipeRef: pipeRef, size: size)
    }

    @discardableResult
    func vendorOut(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, payload: Data = Data()) async throws -> Bool {
        try await transport.vendorOut(deviceIndex: deviceIndex, bRequest: bRequest, wValue: wValue, payload: payload)
    }

    func clearHalt(deviceIndex: Int) async throws {
        try await transport.clearHalt(deviceIndex: deviceIndex)
    }

    func vendorIn(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, wLength: UInt16) async throws -> Data? {
        try await transport.vendorIn(deviceIndex: deviceIndex, bRequest: bRequest, wValue: wValue, wLength: wLength)
    }

    func deviceCount() async -> Int {
        await transport.deviceCount()
    }

    /// Start a background poll on every device except `skipIndex`
    /// (hypothesis Q / Q' — other-device traffic triggers ring drain).
    /// `mode` chooses control (Q, vendor IN bReq=0x49) or bulk (Q', 512 B
    /// bulk OUT). Only supported on the libusb transport; returns false
    /// otherwise. Safe to call when already running — second call is a no-op.
    @discardableResult
    func startOtherDeviceHeartbeatPolling(skipIndex: Int, intervalMs: UInt32, mode: LibUSBHeartbeatPoller.Mode) async -> Bool {
        if heartbeatPoller != nil { return true }
        guard let libusb = transport as? LibUSBTransport else {
            logger.warning("OTHER_DEV_POLL ignored: requires libusb transport")
            return false
        }
        guard let poller = await libusb.makeOtherDeviceHeartbeatPoller(skipIndex: skipIndex, intervalMs: intervalMs, mode: mode) else {
            logger.warning("OTHER_DEV_POLL ignored: no other devices opened (or missing OUT endpoint for bulk mode)")
            return false
        }
        poller.start()
        heartbeatPoller = poller
        return true
    }

    /// SAME_DEV_POLL: poll device `index`'s own control IN concurrently while the
    /// actor writes bulk to it (vendor pattern: async bulk + concurrent
    /// same-device 0x49/0x40 control poll).
    func startSameDeviceHeartbeatPolling(index: Int, intervalMs: UInt32, mode: LibUSBHeartbeatPoller.Mode) async -> Bool {
        if heartbeatPoller != nil { return true }
        guard let libusb = transport as? LibUSBTransport else {
            logger.warning("SAME_DEV_POLL ignored: requires libusb transport")
            return false
        }
        guard let poller = await libusb.makeSameDeviceHeartbeatPoller(index: index, intervalMs: intervalMs, mode: mode) else {
            logger.warning("SAME_DEV_POLL ignored: device index unavailable")
            return false
        }
        poller.start()
        heartbeatPoller = poller
        return true
    }

    func stopOtherDeviceHeartbeatPolling() async {
        if let p = heartbeatPoller {
            p.stop()
            heartbeatPoller = nil
        }
    }

    func disconnect() async {
        if let p = heartbeatPoller {
            p.stop()
            heartbeatPoller = nil
        }
        await transport.disconnect()
        logger.info("USB transport disconnected")
    }
}
