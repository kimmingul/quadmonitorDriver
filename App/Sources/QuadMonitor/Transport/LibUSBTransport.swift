import Foundation
#if canImport(CLibUSB)
import CLibUSB
#endif

enum LibUSBTransportError: Error {
    case unsupported
    case initFailed(Int32)
    case openFailed
    case noMatchingDevices
    case claimFailed(Int32)
    case noWritableEndpoint
    case accessDenied
    case writeFailed(Int32)
    case readFailed(Int32)
    case notConnected
}

extension LibUSBTransportError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupported:
            return "libusb is not available on this build"
        case .initFailed(let code):
            return "libusb_init failed (code: \(code))"
        case .openFailed:
            return "unable to open USB device with provided VID/PID"
        case .noMatchingDevices:
            return "no USB devices matched provided VID/PID"
        case .claimFailed(let code):
            return "failed to claim interface (code: \(code))"
        case .noWritableEndpoint:
            return "no writable endpoint found in active configuration"
        case .accessDenied:
            return "access denied while claiming USB interface (try running with elevated privileges or ensure no competing driver owns the interface)"
        case .writeFailed(let code):
            return "USB write failed (code: \(code))"
        case .readFailed(let code):
            return "USB read failed (code: \(code))"
        case .notConnected:
            return "transport is not connected"
        }
    }
}

#if canImport(CLibUSB)
private struct EndpointLayout {
    let interfaceNumber: UInt8
    let outEndpoint: UInt8?
    let inEndpoint: UInt8?
    let usesInterruptOut: Bool
    let usesInterruptIn: Bool
}

private struct OpenedDevice {
    let handle: OpaquePointer
    let busNumber: UInt8
    let deviceAddress: UInt8
    let layout: EndpointLayout
}

// --- Async multi-device streaming (hypothesis Q': the firmware only drains a
// device's bulk-OUT ring while there is CONCURRENT bulk OUT to the sibling
// displays on the shared hub). libusb's sync API serialises bulk transfers
// within one context, so we use the async API: submit one outstanding transfer
// per device and drive them all from a single event loop, resubmitting on
// completion for a continuous, genuinely concurrent 3-device stream — the
// pattern the vendor app uses (async WritePipe to all displays at once). ---
final class AsyncStreamState: @unchecked Sendable {
    var stopping = false
    var completed: [Int]
    var failed: [Int]
    var lastStatus: [Int32]
    init(deviceCount n: Int) {
        completed = .init(repeating: 0, count: n)
        failed = .init(repeating: 0, count: n)
        lastStatus = .init(repeating: 0, count: n)
    }
}

struct AsyncXferCtx {
    let state: Unmanaged<AsyncStreamState>
    let deviceIndex: Int
}

// C completion callback: tally the result and resubmit the same transfer so each
// device streams continuously. Runs on the thread calling libusb_handle_events.
func racerAsyncStreamCallback(_ xfer: UnsafeMutablePointer<libusb_transfer>?) {
    guard let xfer, let ud = xfer.pointee.user_data else { return }
    let ctx = ud.assumingMemoryBound(to: AsyncXferCtx.self).pointee
    let state = ctx.state.takeUnretainedValue()
    let status = xfer.pointee.status
    state.lastStatus[ctx.deviceIndex] = Int32(status.rawValue)
    if status == LIBUSB_TRANSFER_COMPLETED {
        state.completed[ctx.deviceIndex] += 1
    } else {
        state.failed[ctx.deviceIndex] += 1
    }
    if !state.stopping {
        _ = libusb_submit_transfer(xfer)
    }
}
#endif

actor LibUSBTransport: USBTransport {
    private let logger: Logger
    private let vendorID: UInt16
    private let productID: UInt16

    #if canImport(CLibUSB)
    private var context: OpaquePointer?
    private var openedDevices: [OpenedDevice] = []
    private var vendorPoller: LibUSBHeartbeatPoller?
    #endif

    init(logger: Logger, vendorID: UInt16, productID: UInt16) {
        self.logger = logger
        self.vendorID = vendorID
        self.productID = productID
    }

    func connect() async throws {
        #if canImport(CLibUSB)
        var ctx: OpaquePointer?
        let initRC = libusb_init(&ctx)
        guard initRC == 0, let ctx else {
            throw LibUSBTransportError.initFailed(initRC)
        }
        context = ctx

        var list: UnsafeMutablePointer<OpaquePointer?>?
        let listCount = libusb_get_device_list(ctx, &list)
        guard listCount >= 0, let list else {
            throw LibUSBTransportError.openFailed
        }
        defer { libusb_free_device_list(list, 1) }

        var matches = 0
        var accessDeniedCount = 0
        for i in 0..<Int(listCount) {
            guard let device = list[i] else { continue }

            var descriptor = libusb_device_descriptor()
            let descriptorRC = libusb_get_device_descriptor(device, &descriptor)
            guard descriptorRC == 0 else { continue }

            guard descriptor.idVendor == vendorID, descriptor.idProduct == productID else {
                continue
            }
            matches += 1

            var handle: OpaquePointer?
            let openRC = libusb_open(device, &handle)
            guard openRC == 0, var handle else {
                logger.warning("Failed to open matching device #\(matches), code=\(openRC)")
                continue
            }

            _ = libusb_set_auto_detach_kernel_driver(handle, 1)

            // USB_RESET=1: issue a USB port reset before unlocking, to re-arm the
            // device from a fresh (cold-like) state. Hardware finding
            // (2026-07-02): the device only sustains a frame stream right after a
            // power-cycle cold-start; in warm state (vendor app ran, we took over)
            // it stalls after exactly 1 frame — not scanning out. A host-side bus
            // reset is the closest approximation to a power cycle without
            // physically unplugging. If the device re-enumerates (rc=-5) the
            // handle is dead; we re-open the SAME device node (its libusb_device
            // pointer stays valid across a port reset) before continuing.
            if ProcessInfo.processInfo.environment["USB_RESET"] == "1" {
                let resetRC = libusb_reset_device(handle)
                logger.info("libusb_reset_device rc=\(resetRC) (0=ok, -5=reenumerated) match #\(matches)")
                if resetRC != 0 {
                    libusb_close(handle)
                    try? await Task.sleep(nanoseconds: 300_000_000)   // let the port re-enumerate
                    var reHandle: OpaquePointer?
                    let reopenRC = libusb_open(device, &reHandle)
                    guard reopenRC == 0, let reHandle else {
                        logger.warning("re-open after reset failed rc=\(reopenRC) match #\(matches)")
                        continue
                    }
                    handle = reHandle
                    _ = libusb_set_auto_detach_kernel_driver(handle, 1)
                }
                try? await Task.sleep(nanoseconds: 200_000_000)       // settle before control transfers
            }

            do {
                let layout = try resolveEndpoints(handle: handle)
                let claimRC = libusb_claim_interface(handle, Int32(layout.interfaceNumber))
                guard claimRC == 0 else {
                    libusb_close(handle)
                    logger.warning("Failed to claim interface=\(layout.interfaceNumber), code=\(claimRC)")
                    if claimRC == -3 {
                        accessDeniedCount += 1
                    }
                    continue
                }

                // Explicitly select alt setting 0 — IOKit's IOUSBInterfaceInterface
                // does this implicitly during interface open, so the device may
                // depend on the SET_INTERFACE control transfer to arm bulk endpoints.
                let altRC = libusb_set_interface_alt_setting(handle, Int32(layout.interfaceNumber), 0)
                if altRC != 0 {
                    logger.info("set_interface_alt_setting=0 returned \(altRC) (continuing)")
                }

                let bus = libusb_get_bus_number(device)
                let address = libusb_get_device_address(device)

                // Run the vendor unlock sequence reverse-engineered from the
                // original RacerUSB.app via lldb. Without these control
                // transfers, bulk OUT 0x01 always times out (-7).
                do {
                    try runUnlockSequence(handle: handle, bus: bus, address: address)
                } catch {
                    libusb_release_interface(handle, Int32(layout.interfaceNumber))
                    libusb_close(handle)
                    logger.warning("Unlock sequence failed bus=\(bus) addr=\(address): \(error.localizedDescription)")
                    continue
                }

                // Make sure the bulk OUT pipe is in a clean state — without
                // this, leftover halt conditions from a previous bad write
                // (e.g. a wedged frame from an earlier run) cause every
                // subsequent transfer to time out with -7.
                if let outEp = layout.outEndpoint {
                    let chRC = libusb_clear_halt(handle, outEp)
                    if chRC != 0 {
                        logger.info("clear_halt(0x\(String(format: "%02X", outEp))) returned \(chRC) bus=\(bus) addr=\(address)")
                    }
                }

                openedDevices.append(
                    OpenedDevice(
                        handle: handle,
                        busNumber: bus,
                        deviceAddress: address,
                        layout: layout
                    )
                )

                logger.info(
                    "libusb opened+unlocked device bus=\(bus) addr=\(address) interface=\(layout.interfaceNumber) out=\(layout.outEndpoint.map { String(format: "0x%02X", $0) } ?? "none") in=\(layout.inEndpoint.map { String(format: "0x%02X", $0) } ?? "none")"
                )
            } catch {
                libusb_close(handle)
                logger.warning("Skipping device due to endpoint resolution failure: \(error.localizedDescription)")
            }
        }

        guard matches > 0 else {
            throw LibUSBTransportError.noMatchingDevices
        }
        if accessDeniedCount == matches {
            throw LibUSBTransportError.accessDenied
        }
        guard !openedDevices.isEmpty else {
            throw LibUSBTransportError.noWritableEndpoint
        }

        logger.info("libusb connected to \(openedDevices.count) matching device(s)")

        // LIBUSB_VENDOR_POLL_HZ=N: spawn a background vendor 0xC1 polling
        // thread targeting every opened device (incl. the one we'll be
        // writing to). Mirrors UsbDisplay's 87Hz pattern (§17.3
        // conn=0xec03 sel=7 [0,193,73,0,0,1,ts,5000]). Distinct from the
        // prior `.control` mode polling (cap3 / §16.2) which used a
        // different vendor request and skipped the active device.
        if let hzStr = ProcessInfo.processInfo.environment["LIBUSB_VENDOR_POLL_HZ"],
           let hz = Int(hzStr), hz > 0 {
            let intervalMs = UInt32(max(1, 1000 / hz))
            // bmRequestType: default 0xC0 (IN | vendor | device). Override
            // with LIBUSB_VENDOR_POLL_BMREQ=0x40 (OUT | vendor | device) to
            // mirror UsbDisplay's pre-bulk vendor-0xC1 OUT call observed at
            // [prior log line ~110]: conn=0xec03 sel=7
            // inSc=[0, 193, 73, 0, 0, 1, ts, 5000] — inSc[0]=0 suggests
            // bmReqType=0 (host-to-device) packing under IOUSBLib
            // DeviceRequestTO. Distinct from prior cap3 / first option X
            // attempt which used IN direction (0xC0).
            let bmReq: UInt8 = {
                if let s = ProcessInfo.processInfo.environment["LIBUSB_VENDOR_POLL_BMREQ"] {
                    // accept 0x40 or 64 etc.
                    if s.hasPrefix("0x") || s.hasPrefix("0X") {
                        if let v = UInt8(s.dropFirst(2), radix: 16) { return v }
                    } else if let v = UInt8(s) {
                        return v
                    }
                }
                return 0xC0
            }()
            let bReq: UInt8 = 0xC1
            let wVal: UInt16 = 0x49  // 73
            if let poller = makeAllDeviceVendorPoller(
                bmRequestType: bmReq, bRequest: bReq, wValue: wVal,
                intervalMs: intervalMs
            ) {
                poller.start()
                vendorPoller = poller
                logger.info("LIBUSB_VENDOR_POLL_HZ=\(hz): started bmReq=0x\(String(bmReq, radix: 16)) bReq=0x\(String(bReq, radix: 16)) wVal=0x\(String(wVal, radix: 16)) interval=\(intervalMs)ms across \(openedDevices.count) device(s)")
            }
        }
        #else
        throw LibUSBTransportError.unsupported
        #endif
    }

    func write(_ bytes: Data) async throws {
        #if canImport(CLibUSB)
        guard !openedDevices.isEmpty else {
            throw LibUSBTransportError.notConnected
        }

        var successCount = 0
        var lastError: Int32 = -1

        for entry in openedDevices {
            guard let rc = writeToSingle(entry: entry, bytes: bytes) else {
                continue
            }

            if rc == 0 {
                successCount += 1
            } else {
                lastError = rc
            }
        }

        if successCount == 0 {
            throw LibUSBTransportError.writeFailed(lastError)
        }

        if successCount < openedDevices.count {
            logger.warning("USB write partially succeeded: success=\(successCount), total=\(openedDevices.count)")
        }
        #else
        throw LibUSBTransportError.unsupported
        #endif
    }

    func read(maxBytes: Int) async throws -> Data {
        #if canImport(CLibUSB)
        guard !openedDevices.isEmpty else {
            throw LibUSBTransportError.notConnected
        }

        let entry = openedDevices[0]
        guard let endpoint = entry.layout.inEndpoint else {
            return Data([ProtocolCommand.heartbeat.rawValue, 0, 0])
        }

        let requested = max(1, min(maxBytes, 4096))
        var buffer = [UInt8](repeating: 0, count: requested)
        var transferred: Int32 = 0
        let timeoutMs: UInt32 = 1000

        let rc: Int32 = buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress else { return -2 }
            if entry.layout.usesInterruptIn {
                return libusb_interrupt_transfer(
                    entry.handle,
                    endpoint,
                    base,
                    Int32(requested),
                    &transferred,
                    timeoutMs
                )
            }
            return libusb_bulk_transfer(
                entry.handle,
                endpoint,
                base,
                Int32(requested),
                &transferred,
                timeoutMs
            )
        }

        guard rc == 0 else {
            throw LibUSBTransportError.readFailed(rc)
        }

        return Data(buffer.prefix(Int(transferred)))
        #else
        throw LibUSBTransportError.unsupported
        #endif
    }

    func disconnect() async {
        #if canImport(CLibUSB)
        if let poller = vendorPoller {
            poller.stop()
            vendorPoller = nil
        }
        for entry in openedDevices {
            libusb_release_interface(entry.handle, Int32(entry.layout.interfaceNumber))
            libusb_close(entry.handle)
        }
        openedDevices.removeAll(keepingCapacity: false)

        if let context {
            libusb_exit(context)
            self.context = nil
        }
        #endif
    }

    func deviceCount() async -> Int {
        #if canImport(CLibUSB)
        return openedDevices.count
        #else
        return 0
        #endif
    }

    func writeRaw(deviceIndex: Int, bytes: Data) async throws {
        #if canImport(CLibUSB)
        guard !openedDevices.isEmpty else {
            throw LibUSBTransportError.notConnected
        }
        guard deviceIndex >= 0, deviceIndex < openedDevices.count else {
            throw LibUSBTransportError.notConnected
        }
        let entry = openedDevices[deviceIndex]
        // NOTE: dropped the trailing +1 0xFF padding — that experiment made
        // no positive difference and may corrupt JPEG end-of-stream detection.
        let padded = bytes
        var transferred: Int32 = 0
        let rc = transfer(
            entry: entry,
            endpoint: entry.layout.outEndpoint ?? 0x01,
            bytes: padded,
            forceInterrupt: entry.layout.usesInterruptOut,
            transferred: &transferred,
            timeoutMs: 5000
        )

        if rc != 0 {
            logger.warning(
                "bulk write FAILED bus=\(entry.busNumber) addr=\(entry.deviceAddress) rc=\(rc) sent=\(transferred)/\(padded.count)"
            )
            throw LibUSBTransportError.writeFailed(rc)
        }
        logger.info("bulk write OK bus=\(entry.busNumber) addr=\(entry.deviceAddress) sent=\(transferred)/\(padded.count)")
        #else
        throw LibUSBTransportError.unsupported
        #endif
    }

    func vendorOut(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, payload: Data) async throws -> Bool {
        #if canImport(CLibUSB)
        guard deviceIndex >= 0, deviceIndex < openedDevices.count else {
            throw LibUSBTransportError.notConnected
        }
        let entry = openedDevices[deviceIndex]
        return vendorWrite(handle: entry.handle, bRequest: bRequest, wValue: wValue, payload: payload)
        #else
        throw LibUSBTransportError.unsupported
        #endif
    }

    func clearHalt(deviceIndex: Int) async throws {
        #if canImport(CLibUSB)
        guard deviceIndex >= 0, deviceIndex < openedDevices.count else {
            throw LibUSBTransportError.notConnected
        }
        let entry = openedDevices[deviceIndex]
        if let outEp = entry.layout.outEndpoint {
            let rc = libusb_clear_halt(entry.handle, outEp)
            if rc != 0 {
                logger.info("clear_halt(0x\(String(format: "%02X", outEp))) rc=\(rc) bus=\(entry.busNumber) addr=\(entry.deviceAddress)")
            }
        }
        #else
        throw LibUSBTransportError.unsupported
        #endif
    }

    func vendorIn(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, wLength: UInt16) async throws -> Data? {
        #if canImport(CLibUSB)
        guard deviceIndex >= 0, deviceIndex < openedDevices.count else {
            throw LibUSBTransportError.notConnected
        }
        let entry = openedDevices[deviceIndex]
        return vendorRead(handle: entry.handle, bRequest: bRequest, wValue: wValue, wLength: wLength)
        #else
        throw LibUSBTransportError.unsupported
        #endif
    }

    /// Build a poller that hits every device except `skipIndex` at
    /// `intervalMs` cadence from a dedicated POSIX thread. libusb transfer
    /// functions are thread-safe per handle, so the polling runs truly
    /// concurrently with whatever the actor is doing on `skipIndex`
    /// (e.g. a blocked bulk_transfer). Returns nil if no other devices
    /// are open or — for bulk mode — if any other device lacks an OUT
    /// endpoint.
    /// Build a poller targeting EVERY opened device (no skipIndex) that
    /// sends a vendor-specific control request at `intervalMs` cadence.
    /// Used to mirror UsbDisplay 's 87Hz 0xC1 / wValue=0x49 pattern
    /// (§17.3) on the bulk-active device itself, which the prior
    /// `makeOtherDeviceHeartbeatPoller` path could not test.
    func makeAllDeviceVendorPoller(bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16, intervalMs: UInt32) -> LibUSBHeartbeatPoller? {
        #if canImport(CLibUSB)
        guard !openedDevices.isEmpty else { return nil }
        let targets = openedDevices.map {
            LibUSBHeartbeatPoller.Target(handle: $0.handle, outEndpoint: 0)
        }
        return LibUSBHeartbeatPoller(
            targets: targets,
            mode: .vendor(bmRequestType: bmRequestType, bRequest: bRequest, wValue: wValue),
            intervalMs: intervalMs,
            logger: logger
        )
        #else
        return nil
        #endif
    }

    /// Poller that hits ONLY device `index` (the same one the actor is writing
    /// to), from a dedicated thread, bypassing the actor. The vendor app drives
    /// async bulk OUT while concurrently polling the SAME device's 0x49/0x40
    /// control IN at ~22Hz — a candidate ring-drain handshake we can't do with a
    /// blocking sync bulk write on one thread. Control transfers use a different
    /// endpoint than bulk, so they reach the wire concurrently even while the
    /// bulk write NAK-storms (verified for cross-device control in cap3).
    func makeSameDeviceHeartbeatPoller(index: Int, intervalMs: UInt32, mode: LibUSBHeartbeatPoller.Mode) -> LibUSBHeartbeatPoller? {
        #if canImport(CLibUSB)
        guard index >= 0, index < openedDevices.count else { return nil }
        let entry = openedDevices[index]
        let target: LibUSBHeartbeatPoller.Target
        switch mode {
        case .control, .vendor:
            target = LibUSBHeartbeatPoller.Target(handle: entry.handle, outEndpoint: 0)
        case .bulk:
            guard let ep = entry.layout.outEndpoint else { return nil }
            target = LibUSBHeartbeatPoller.Target(handle: entry.handle, outEndpoint: ep)
        }
        return LibUSBHeartbeatPoller(targets: [target], mode: mode, intervalMs: intervalMs, logger: logger)
        #else
        return nil
        #endif
    }

    func makeOtherDeviceHeartbeatPoller(skipIndex: Int, intervalMs: UInt32, mode: LibUSBHeartbeatPoller.Mode) -> LibUSBHeartbeatPoller? {
        #if canImport(CLibUSB)
        let others = openedDevices.enumerated()
            .filter { $0.offset != skipIndex }
            .map { $0.element }
        guard !others.isEmpty else { return nil }
        let targets: [LibUSBHeartbeatPoller.Target] = others.compactMap { entry in
            switch mode {
            case .control, .vendor:
                return LibUSBHeartbeatPoller.Target(handle: entry.handle, outEndpoint: 0)
            case .bulk:
                guard let ep = entry.layout.outEndpoint else { return nil }
                return LibUSBHeartbeatPoller.Target(handle: entry.handle, outEndpoint: ep)
            }
        }
        guard targets.count == others.count else { return nil }
        return LibUSBHeartbeatPoller(targets: targets, mode: mode, intervalMs: intervalMs, logger: logger)
        #else
        return nil
        #endif
    }

    #if canImport(CLibUSB)
    private func writeToSingle(entry: OpenedDevice, bytes: Data) -> Int32? {
        guard let endpoint = entry.layout.outEndpoint else {
            return -5
        }

        var transferred: Int32 = 0
        let timeoutMs: UInt32 = 1500

        let rc = transfer(
            entry: entry,
            endpoint: endpoint,
            bytes: bytes,
            forceInterrupt: entry.layout.usesInterruptOut,
            transferred: &transferred,
            timeoutMs: timeoutMs
        )

        if rc != 0 {
            logger.warning(
                "Bulk write failed bus=\(entry.busNumber) addr=\(entry.deviceAddress) ep=\(String(format: "0x%02X", endpoint)) bytes=\(bytes.count) code=\(rc)"
            )
        }
        return rc
    }

    private func transfer(
        entry: OpenedDevice,
        endpoint: UInt8,
        bytes: Data,
        forceInterrupt: Bool,
        transferred: inout Int32,
        timeoutMs: UInt32
    ) -> Int32 {
        // LIBUSB_CHUNK_BYTES=N — split the OUT transfer into N-byte chunks
        // and call libusb_bulk_transfer once per chunk. UsbDisplay sends
        // 825K frames via IOUSBLib classic plugin's WritePipe in chunks
        // of 5K–140K (max 142,977B observed); a single 825K libusb call
        // hits the 8KB wall on macOS 26. Default 0 = no split (legacy).
        let chunkSize: Int = {
            if let s = ProcessInfo.processInfo.environment["LIBUSB_CHUNK_BYTES"],
               let n = Int(s), n > 0 {
                return n
            }
            return 0
        }()

        return bytes.withUnsafeBytes { rawBuffer -> Int32 in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
                return -2
            }

            let total = bytes.count
            let stride = (chunkSize > 0 && total > chunkSize) ? chunkSize : total
            transferred = 0
            var offset = 0

            while offset < total {
                let n = min(stride, total - offset)
                var chunkTransferred: Int32 = 0
                let chunkPtr = UnsafeMutablePointer(mutating: base.advanced(by: offset))
                let rc: Int32
                if forceInterrupt {
                    rc = libusb_interrupt_transfer(
                        entry.handle,
                        endpoint,
                        chunkPtr,
                        Int32(n),
                        &chunkTransferred,
                        timeoutMs
                    )
                } else {
                    rc = libusb_bulk_transfer(
                        entry.handle,
                        endpoint,
                        chunkPtr,
                        Int32(n),
                        &chunkTransferred,
                        timeoutMs
                    )
                }
                transferred += chunkTransferred
                if rc != 0 {
                    return rc
                }
                // Device may legitimately return fewer bytes (short packet).
                // Advance by what was actually transferred to keep stream
                // alignment; bail if it stalled at zero to avoid infinite
                // loop.
                if chunkTransferred == 0 { break }
                offset += Int(chunkTransferred)
            }
            return 0
        }
    }

    /// JPEG quantization tables (Y + C) reverse-engineered from the original
    /// RacerUSB.app via lldb tracing. The device uses these tables to decode
    /// every JPEG frame sent over bulk OUT, so they must be uploaded before
    /// any frame data — otherwise bulk OUT 0x01 always times out (-7).
    static let bulkUnlockDQT: [UInt8] = [
        0xff, 0xdb, 0x00, 0x43, 0x00,
        0x02, 0x01, 0x01, 0x02, 0x02, 0x04, 0x05, 0x06, 0x01, 0x01, 0x01, 0x02,
        0x03, 0x06, 0x06, 0x06, 0x01, 0x01, 0x02, 0x02, 0x04, 0x06, 0x07, 0x06,
        0x01, 0x02, 0x02, 0x03, 0x05, 0x09, 0x08, 0x06, 0x02, 0x02, 0x04, 0x06,
        0x07, 0x0b, 0x0a, 0x08, 0x02, 0x04, 0x06, 0x06, 0x08, 0x0a, 0x0b, 0x09,
        0x05, 0x06, 0x08, 0x09, 0x0a, 0x0c, 0x0c, 0x0a, 0x07, 0x09, 0x0a, 0x0a,
        0x0b, 0x0a, 0x0a, 0x0a,
        0xff, 0xdb, 0x00, 0x43, 0x01,
        0x02, 0x02, 0x02, 0x05, 0x0a, 0x0a, 0x0a, 0x0a, 0x02, 0x02, 0x03, 0x07,
        0x0a, 0x0a, 0x0a, 0x0a, 0x02, 0x03, 0x06, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a,
        0x05, 0x07, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a,
        0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a,
        0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a, 0x0a,
        0x0a, 0x0a
    ]

    /// Walk the original-app initialisation sequence captured by lldb, then
    /// upload the JPEG quantisation tables and resolution required to unlock
    /// the bulk OUT pipe.
    private func runUnlockSequence(handle: OpaquePointer, bus: UInt8, address: UInt8) throws {
        // Vendor IN reads — the device appears to require these to be issued
        // before it accepts the OUT configuration writes. Failures are tolerated
        // (some devices skip 0x49 in the captured trace).
        let initReads: [(UInt8, UInt16, UInt16)] = [
            (0x40, 0,   2),   // status
            (0x50, 0,   4),   // mode descriptor
            (0x51, 0,   2),
            (0x52, 0,   2),
            (0x49, 0,   1),   // heartbeat
            (0x41, 0,   2),   // EDID header
            (0x41, 1, 128),   // EDID block 1
            (0x41, 2, 128)    // EDID block 2
        ]
        for (req, value, length) in initReads {
            _ = vendorRead(handle: handle, bRequest: req, wValue: value, wLength: length)
        }

        // Upload JPEG quantisation tables (138 B): bmRT=0x41 bReq=0x83 wValue=1
        let dqt = Data(LibUSBTransport.bulkUnlockDQT)
        guard vendorWrite(handle: handle, bRequest: 0x83, wValue: 1, payload: dqt) else {
            throw LibUSBTransportError.writeFailed(-1)
        }

        // Set frame resolution (LE u16 width, LE u16 height). 1920x1200 default;
        // a future revision should parse the EDID block for the panel's preferred
        // detailed-timing.
        // The captured lldb trace shows the original app issues this exact OUT
        // twice in a row per device (and only DQT once); replicate that — the
        // second send may arm a state the firmware needs before bulk OUT.
        let resolution = Data([0x80, 0x07, 0xb0, 0x04])
        guard vendorWrite(handle: handle, bRequest: 0x81, wValue: 0, payload: resolution) else {
            throw LibUSBTransportError.writeFailed(-2)
        }
        guard vendorWrite(handle: handle, bRequest: 0x81, wValue: 0, payload: resolution) else {
            throw LibUSBTransportError.writeFailed(-3)
        }

        // SET_ALT_INTERFACE=N — send a raw standard SET_INTERFACE(altSetting=N)
        // request, ignoring the result. The vendor's cold-start trace
        // (2026-06-28) shows `sel=5 in=[1]` on the IOUSBHostInterface UC before
        // streaming = SetAlternateInterface(1). Our IOKit path reported
        // kIOReturnNotFound for it, but that may be the host API failing to
        // re-enumerate pipes for an unadvertised alt 1 *after* the device
        // already received SET_INTERFACE(1) and switched its firmware into
        // streaming/scanout mode. We send the control request directly and
        // ignore the (expected) error, then see if the bulk ring drains past
        // 16384. bmRT=0x01 (Host->Dev, Standard, Interface), bReq=0x0B.
        if let altStr = ProcessInfo.processInfo.environment["SET_ALT_INTERFACE"],
           let alt = UInt16(altStr) {
            let rc = libusb_control_transfer(handle, 0x01, 0x0B, alt, 0, nil, 0, 1000)
            logger.info("SET_INTERFACE(alt=\(alt)) raw control rc=\(rc) (ignored)")
        }

        logger.info("Vendor unlock sequence completed bus=\(bus) addr=\(address)")
    }

    /// Hypothesis Q' test — stream `frame` to ALL opened devices concurrently via
    /// the libusb async API for `seconds`, resubmitting on completion so every
    /// display has an outstanding bulk-OUT transfer at all times. Logs per-device
    /// completed/failed counts once a second. If the firmware's ring-drain is
    /// gated on concurrent sibling traffic, `completed` should climb for all
    /// devices instead of stalling after one frame (the single-device symptom).
    func streamAllDevicesAsync(frame: [UInt8], seconds: Int) async {
        #if canImport(CLibUSB)
        guard let ctx = context, !openedDevices.isEmpty else {
            logger.warning("stream-all: not connected"); return
        }
        let n = openedDevices.count
        let state = AsyncStreamState(deviceCount: n)
        let stateU = Unmanaged.passRetained(state)
        defer { stateU.release() }

        var buffers: [UnsafeMutablePointer<UInt8>] = []
        var xferCtxs: [UnsafeMutablePointer<AsyncXferCtx>] = []
        var transfers: [OpaquePointer] = []
        for i in 0..<n {
            guard let outEp = openedDevices[i].layout.outEndpoint else { continue }
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: frame.count)
            frame.withUnsafeBufferPointer { buf.update(from: $0.baseAddress!, count: frame.count) }
            buffers.append(buf)
            let cctx = UnsafeMutablePointer<AsyncXferCtx>.allocate(capacity: 1)
            cctx.initialize(to: AsyncXferCtx(state: stateU, deviceIndex: i))
            xferCtxs.append(cctx)
            guard let xfer = libusb_alloc_transfer(0) else { continue }
            libusb_fill_bulk_transfer(xfer, openedDevices[i].handle, outEp, buf,
                                      Int32(frame.count), racerAsyncStreamCallback, cctx, 1000)
            let sr = libusb_submit_transfer(xfer)
            if sr != 0 { logger.warning("stream-all: submit dev \(i) rc=\(sr)") }
            transfers.append(OpaquePointer(xfer))
        }
        logger.info("stream-all: \(transfers.count)/\(n) devices streaming, frame=\(frame.count)B for \(seconds)s")

        let startNs = DispatchTime.now().uptimeNanoseconds
        let deadlineNs = startNs &+ UInt64(seconds) &* 1_000_000_000
        var lastLogNs = startNs
        while DispatchTime.now().uptimeNanoseconds < deadlineNs {
            var tv = timeval(tv_sec: 0, tv_usec: 100_000)
            libusb_handle_events_timeout_completed(ctx, &tv, nil)
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastLogNs > 1_000_000_000 {
                let secs = Double(now &- startNs) / 1_000_000_000
                logger.info(String(format: "stream-all t+%.1fs completed=%@ failed=%@ lastStatus=%@",
                                   secs, "\(state.completed)", "\(state.failed)", "\(state.lastStatus)"))
                lastLogNs = now
            }
        }

        state.stopping = true
        for x in transfers { libusb_cancel_transfer(UnsafeMutablePointer<libusb_transfer>(x)) }
        for _ in 0..<20 {
            var tv = timeval(tv_sec: 0, tv_usec: 50_000)
            libusb_handle_events_timeout_completed(ctx, &tv, nil)
        }
        for x in transfers { libusb_free_transfer(UnsafeMutablePointer<libusb_transfer>(x)) }
        for b in buffers { b.deallocate() }
        for c in xferCtxs { c.deallocate() }
        logger.info("stream-all COMPLETE: completed=\(state.completed) failed=\(state.failed) (per-device frames drained)")
        #endif
    }

    @discardableResult
    private func vendorRead(handle: OpaquePointer, bRequest: UInt8, wValue: UInt16, wLength: UInt16) -> Data? {
        var buffer = [UInt8](repeating: 0, count: Int(wLength))
        let rc: Int32 = buffer.withUnsafeMutableBufferPointer { ptr in
            libusb_control_transfer(
                handle,
                0xC1,           // bmRequestType: Vendor / Interface / IN
                bRequest,
                wValue,
                0,              // wIndex
                ptr.baseAddress,
                wLength,
                500
            )
        }
        return rc >= 0 ? Data(buffer.prefix(Int(rc))) : nil
    }

    private func vendorWrite(handle: OpaquePointer, bRequest: UInt8, wValue: UInt16, payload: Data) -> Bool {
        var bytes = [UInt8](payload)
        let length = UInt16(bytes.count)
        let rc: Int32 = bytes.withUnsafeMutableBufferPointer { ptr in
            libusb_control_transfer(
                handle,
                0x41,           // bmRequestType: Vendor / Interface / OUT
                bRequest,
                wValue,
                0,              // wIndex
                ptr.baseAddress,
                length,
                500
            )
        }
        if rc < 0 {
            logger.warning("vendor OUT bReq=\(String(format: "0x%02X", bRequest)) wVal=\(wValue) len=\(length) failed rc=\(rc)")
            return false
        }
        return true
    }

    private func resolveEndpoints(handle: OpaquePointer) throws -> EndpointLayout {
        var configDescriptor: UnsafeMutablePointer<libusb_config_descriptor>?
        let configRC = libusb_get_active_config_descriptor(libusb_get_device(handle), &configDescriptor)
        guard configRC == 0, let configDescriptor else {
            throw LibUSBTransportError.openFailed
        }
        defer { libusb_free_config_descriptor(configDescriptor) }

        var candidate: EndpointLayout?

        let interfaceCount = Int(configDescriptor.pointee.bNumInterfaces)
        for i in 0..<interfaceCount {
            let interface = configDescriptor.pointee.interface.advanced(by: i).pointee
            let altSettingCount = Int(interface.num_altsetting)

            for j in 0..<altSettingCount {
                let alt = interface.altsetting.advanced(by: j).pointee

                var outEndpoint: UInt8?
                var inEndpoint: UInt8?
                var usesInterruptOut = false
                var usesInterruptIn = false

                let endpointCount = Int(alt.bNumEndpoints)
                logger.info("Interface \(alt.bInterfaceNumber) alt \(alt.bAlternateSetting): \(endpointCount) endpoints, class=0x\(String(format: "%02X", alt.bInterfaceClass))")
                for k in 0..<endpointCount {
                    let endpoint = alt.endpoint.advanced(by: k).pointee
                    let address = endpoint.bEndpointAddress
                    let transferType = endpoint.bmAttributes & 0x03
                    let isIn = (address & 0x80) != 0
                    let isBulk = transferType == 0x02
                    let isInterrupt = transferType == 0x03
                    let typeName: String
                    switch transferType {
                    case 0: typeName = "control"
                    case 1: typeName = "iso"
                    case 2: typeName = "bulk"
                    case 3: typeName = "intr"
                    default: typeName = "?"
                    }
                    logger.info("EP descriptor: addr=\(String(format: "0x%02X", address)) dir=\(isIn ? "IN" : "OUT") type=\(typeName) wMaxPacketSize=\(endpoint.wMaxPacketSize) bInterval=\(endpoint.bInterval)")

                    if !isIn, outEndpoint == nil, (isBulk || isInterrupt) {
                        outEndpoint = address
                        usesInterruptOut = isInterrupt
                    } else if isIn, inEndpoint == nil, (isBulk || isInterrupt) {
                        inEndpoint = address
                        usesInterruptIn = isInterrupt
                    }
                }

                if outEndpoint != nil || inEndpoint != nil {
                    candidate = EndpointLayout(
                        interfaceNumber: alt.bInterfaceNumber,
                        outEndpoint: outEndpoint,
                        inEndpoint: inEndpoint,
                        usesInterruptOut: usesInterruptOut,
                        usesInterruptIn: usesInterruptIn
                    )

                    if outEndpoint != nil {
                        return candidate!
                    }
                }
            }
        }

        if let candidate {
            return candidate
        }

        throw LibUSBTransportError.noWritableEndpoint
    }
    #endif
}

/// Background poller used to test hypothesis Q (other-device USB traffic
/// triggers the firmware bulk-OUT ring drain). Holds raw libusb handles
/// and pokes them from a dedicated Thread, bypassing the actor's mailbox
/// so polling proceeds even while the actor is blocked inside a long
/// libusb_bulk_transfer.
///
/// - `.control` mode: vendor IN bReq=0x49 (heartbeat) — cheap, cap3 result.
/// - `.bulk` mode: short bulk OUT (512 B 0x55-fill) on each device's OUT
///   endpoint — cap1b-faithful traffic shape. Hypothesis Q' candidate.
final class LibUSBHeartbeatPoller: @unchecked Sendable {
    enum Mode {
        case control
        case bulk
        /// Vendor-specific control request to ALL passed targets at a fixed
        /// cadence. Mirrors UsbDisplay's §17.3 conn=0xec03 sel=7 8-arg
        /// pattern [0, 193, 73, 0, 0, 1, ts, 5000] @ 87Hz — bRequest=0xC1,
        /// wValue=0x49 (73), wLength=0. Distinct from `.control` (which
        /// uses bReq=0x49, wValue=0, wLength=1 and was falsified for
        /// 8KB-wall release by cap3 §16); the request fields swap and
        /// the targets include the bulk-active device itself.
        case vendor(bmRequestType: UInt8, bRequest: UInt8, wValue: UInt16)
    }

    struct Target {
        let handle: OpaquePointer
        let outEndpoint: UInt8  // 0 when mode == .control (unused)
    }

    private let targets: [Target]
    private let mode: Mode
    private let intervalMs: UInt32
    private let logger: Logger
    private let lock = NSLock()
    private var stopRequested = false
    private var started = false
    private let done = DispatchSemaphore(value: 0)

    fileprivate init(targets: [Target], mode: Mode, intervalMs: UInt32, logger: Logger) {
        self.targets = targets
        self.mode = mode
        self.intervalMs = intervalMs
        self.logger = logger
    }

    func start() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        let t = Thread { [weak self] in self?.run() }
        t.name = "RacerUSB.OTHER_DEV_POLL"
        t.start()
    }

    func stop() {
        lock.lock()
        let wasRunning = started && !stopRequested
        stopRequested = true
        lock.unlock()
        if wasRunning {
            done.wait()
        }
    }

    private var shouldStop: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    private func run() {
        #if canImport(CLibUSB)
        var iterations = 0
        var failures = 0
        let sleepUs = useconds_t(intervalMs) * 1000
        let modeLabel: String
        switch mode {
        case .control: modeLabel = "control bReq=0x49"
        case .bulk:    modeLabel = "bulk OUT 512B"
        case .vendor(let bmReq, let bReq, let wVal):
            modeLabel = String(format: "vendor bmReq=0x%02X bReq=0x%02X wVal=0x%04X", bmReq, bReq, wVal)
        }
        logger.info("OTHER_DEV_POLL started devices=\(targets.count) mode=\(modeLabel) interval=\(intervalMs)ms")

        // Bulk-mode payload: 512 B 0x55 = exactly one wMaxPacketSize HS bulk
        // packet. Adds 1 entry to the target device's 16-packet ring per
        // poll. At 22Hz cadence the ring drains naturally between polls.
        var bulkPayload = [UInt8](repeating: 0x55, count: 512)

        while !shouldStop {
            for target in targets {
                let rc: Int32
                switch mode {
                case .control:
                    var byte: UInt8 = 0
                    rc = withUnsafeMutablePointer(to: &byte) { ptr -> Int32 in
                        libusb_control_transfer(target.handle, 0xC1, 0x49, 0, 0, ptr, 1, 200)
                    }
                case .bulk:
                    var transferred: Int32 = 0
                    rc = bulkPayload.withUnsafeMutableBufferPointer { ptr -> Int32 in
                        libusb_bulk_transfer(
                            target.handle,
                            target.outEndpoint,
                            ptr.baseAddress,
                            Int32(ptr.count),
                            &transferred,
                            30  // 30 ms — shorter than poll interval so a
                                // wedged ring doesn't stall the poll loop
                        )
                    }
                case .vendor(let bmReq, let bReq, let wVal):
                    // UsbDisplay 's 87Hz pattern — control transfer with no
                    // data phase (wLength=0). libusb accepts nil data when
                    // wLength=0; the request is a pure setup packet.
                    rc = libusb_control_transfer(
                        target.handle, bmReq, bReq, wVal, 0, nil, 0,
                        50  // 50 ms — well below the poll interval
                    )
                }
                if rc < 0 { failures += 1 }
            }
            iterations += 1
            if sleepUs > 0 { usleep(sleepUs) }
        }
        logger.info("OTHER_DEV_POLL stopped iterations=\(iterations) failures=\(failures)")
        #endif
        done.signal()
    }
}
