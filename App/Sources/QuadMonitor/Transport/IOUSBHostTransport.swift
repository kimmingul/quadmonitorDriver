import Foundation
import ObjectiveC
import IOSurface
#if canImport(IOUSBHost)
import IOUSBHost
import IOKit
#endif

enum IOUSBHostTransportError: Error, LocalizedError {
    case unsupported
    case noMatchingDevices
    case openFailed(String)
    case pipeNotFound(UInt8)
    case writeFailed(String)
    case unlockFailed(String)
    case notConnected

    var errorDescription: String? {
        switch self {
        case .unsupported: return "IOUSBHost framework not available on this build"
        case .noMatchingDevices: return "no USB DISP interfaces matched"
        case .openFailed(let m): return "IOUSBHost open failed: \(m)"
        case .pipeNotFound(let ep): return "pipe 0x\(String(format: "%02X", ep)) not found"
        case .writeFailed(let m): return "IOUSBHost write failed: \(m)"
        case .unlockFailed(let m): return "vendor unlock failed: \(m)"
        case .notConnected: return "transport not connected"
        }
    }
}

#if canImport(IOUSBHost)
private final class IOUSBHostDeviceHandle: @unchecked Sendable {
    let interface: IOUSBHostInterface
    let bulkOut: IOUSBHostPipe
    let locationID: String
    // Optional second-channel raw user client (kIOUSBDeviceUserClient,
    // type=1) on the parent IOUSBHostDevice service. This mirrors the
    // pattern UsbDisplay.app uses (1× InterfaceUC + 2× DeviceUC per
    // device) and is what we suspect carries the ring-drain trigger
    // calls (sel=10 with a 13-byte frame counter struct).
    var rawDeviceConn: io_connect_t = 0
    var ringTokenCounter: UInt8 = 0x6a
    // Phase B: io_connect_t borrowed from the framework's IOUSBHostPipe
    // (IOUSBHostIOSource._ioConnection ivar). Each pipe has its own
    // user-client conn; bulk writes dispatch through the pipe conn
    // (not the interface conn). Owned by the framework — never close.
    var rawInterfaceConn: io_connect_t = 0
    var pipeEndpoint: UInt64 = 1

    init(interface: IOUSBHostInterface, bulkOut: IOUSBHostPipe, locationID: String) {
        self.interface = interface
        self.bulkOut = bulkOut
        self.locationID = locationID
    }
}
#endif

/// USB transport using Apple's IOUSBHost framework — the modern,
/// dispatch-queue-based USB API that the original UsbDisplay.app uses
/// on macOS 26 (verified via lldb trace 2026-04-25). The legacy
/// IOUSBLib + libusb path has an 8 KB-per-session bulk OUT cap on
/// macOS 26 / Apple Silicon; IOUSBHost does not.
actor IOUSBHostTransport: USBTransport {
    private let logger: Logger
    private let vendorID: UInt16
    private let productID: UInt16

    #if canImport(IOUSBHost)
    private var devices: [IOUSBHostDeviceHandle] = []
    private let queue = DispatchQueue(label: "com.racer.optimized.iousbhost", qos: .userInitiated)
    #endif

    init(logger: Logger, vendorID: UInt16, productID: UInt16) {
        self.logger = logger
        self.vendorID = vendorID
        self.productID = productID
    }

    func connect() async throws {
        #if canImport(IOUSBHost)
        // Match IOUSBHostInterface services with the given idVendor/idProduct.
        // IMPORTANT: idVendor/idProduct must go in a nested IOPropertyMatch
        // dict, NOT at the top level — top-level keys are reserved for
        // IOService meta-keys (IOProviderClass, kIORegistryEntryIDMatching).
        // Empirically verified: top-level idVendor returns 0 matches; nested
        // returns the expected 3 (verified 2026-04-25 on macOS 26).
        let matchDict: [String: Any] = [
            "IOProviderClass": "IOUSBHostInterface",
            "IOPropertyMatch": [
                "idVendor": NSNumber(value: Int32(vendorID)),
                "idProduct": NSNumber(value: Int32(productID))
            ]
        ]
        let matching = matchDict as CFDictionary
        var iter: io_iterator_t = 0
        let getRC = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iter)
        guard getRC == KERN_SUCCESS else {
            throw IOUSBHostTransportError.openFailed("IOServiceGetMatchingServices rc=\(getRC)")
        }
        defer { IOObjectRelease(iter) }

        var opened = 0
        while case let service = IOIteratorNext(iter), service != 0 {
            defer { IOObjectRelease(service) }

            do {
                let intf = try IOUSBHostInterface(
                    __ioService: service,
                    options: [],
                    queue: queue,
                    interestHandler: nil
                )

                // alt=1 path removed 2026-05-19 — falsified per HANDOFF §18.3.
                // ioreg shows UsbDisplay streams at alt=0 with
                // bNumConfigurations=1; only alt=0 is advertised. Device runs
                // at alt=0 by default after IOUSBHostInterface open.

                guard let pipe = try? intf.copyPipe(withAddress: 0x01) else {
                    logger.warning("IOUSBHost: device service has no bulk OUT 0x01 pipe — skipping")
                    continue
                }

                let locID = (try? service.locationIDHex()) ?? "?"
                let handle = IOUSBHostDeviceHandle(interface: intf, bulkOut: pipe, locationID: locID)
                try await runUnlockSequence(handle: handle)

                // IOUSBHOST_RAW_PROBE=1 (Phase A — observation only):
                // open a 2nd raw conn on the same IOUSBHostInterface
                // service alongside the framework's conn. UsbDisplay
                // trace shows IOConnectCallMethod sel=7 carries 800KB+
                // bulk writes, while framework __sendIORequest (sel=22)
                // caps at 8KB. Phase A only tests whether dual-conn
                // open is permitted; sel=2 is read-only; no transfer.
                if ProcessInfo.processInfo.environment["IOUSBHOST_RAW_PROBE"] == "1" {
                    var rawConn: io_connect_t = 0
                    let rcOpen = IOServiceOpen(service, mach_task_self_, 1, &rawConn)
                    let rcOpenHex = String(format: "0x%08X", rcOpen)
                    logger.info("RAW_PROBE: IOServiceOpen(IOUSBHostInterface,type=1) loc=\(locID) rc=\(rcOpenHex) conn=0x\(String(rawConn, radix: 16))")
                    if rcOpen == KERN_SUCCESS, rawConn != 0 {
                        var outSc = [UInt64](repeating: 0, count: 4)
                        var outCnt: UInt32 = 4
                        let rcSel2 = outSc.withUnsafeMutableBufferPointer { p in
                            IOConnectCallScalarMethod(rawConn, 2, nil, 0, p.baseAddress, &outCnt)
                        }
                        let rcSel2Hex = String(format: "0x%08X", rcSel2)
                        let outHex = outSc.prefix(Int(outCnt)).map { String(format: "0x%llx", $0) }
                        logger.info("RAW_PROBE: sel=2 (no-arg read) loc=\(locID) rc=\(rcSel2Hex) outCnt=\(outCnt) out=\(outHex)")
                        IOServiceClose(rawConn)
                    }
                }

                // IOUSBHOST_RAW_BULK=1 (Phase B): retain a raw conn
                // on the interface IOService so writeRaw() can route
                // bulk transfers via IOConnectCallMethod sel=7 instead
                // of the framework's __sendIORequest (sel=22, 8KB cap).
                // IOUSBHOST_INTROSPECT=1 (option-2 PoC):
                // dump the framework's IOUSBHostInterface ObjC ivar
                // layout so we can identify the io_connect_t (uint32,
                // type encoding 'I') it holds, then extract+reuse it
                // for raw IOConnectCallMethod sel=7 calls — bypassing
                // the framework's __sendIORequest (sel=22, 8KB cap)
                // without opening a 2nd conn (sel=0 ExclusiveAccess).
                if ProcessInfo.processInfo.environment["IOUSBHOST_INTROSPECT"] == "1" {
                    func dumpIvars(_ obj: AnyObject, label: String) {
                        var cls: AnyClass? = object_getClass(obj)
                        while let c = cls {
                            let cname = String(cString: class_getName(c))
                            var count: UInt32 = 0
                            if let ivars = class_copyIvarList(c, &count) {
                                for i in 0..<Int(count) {
                                    let ivar = ivars[i]
                                    let nm = ivar_getName(ivar).map { String(cString: $0) } ?? "?"
                                    let ty = ivar_getTypeEncoding(ivar).map { String(cString: $0) } ?? "?"
                                    let off = ivar_getOffset(ivar)
                                    logger.info("INTROSPECT[\(label)]: \(cname).\(nm) type=\(ty) offset=\(off) loc=\(locID)")
                                }
                                free(ivars)
                            }
                            cls = class_getSuperclass(c)
                            if cls == NSObject.self { break }
                        }
                    }
                    dumpIvars(intf, label: "intf")
                    dumpIvars(pipe, label: "pipe")
                }

                if ProcessInfo.processInfo.environment["IOUSBHOST_RAW_BULK"] == "1" {
                    // Option 2 refined: extract io_connect_t from the
                    // pipe (not the interface). Each IOUSBHostPipe has
                    // its own user-client conn (IOUSBHostIOSource.
                    // _ioConnection, offset 12). Bulk transfers
                    // dispatch through this pipe conn — calling sel=7
                    // on the interface conn returned BadArgument
                    // because no pipe was registered there (framework
                    // architecture is layered, unlike UsbDisplay's
                    // single-conn approach). NEVER close — borrowed.
                    let pipeCls: AnyClass = object_getClass(pipe)!
                    if let connIvar = class_getInstanceVariable(pipeCls, "_ioConnection") {
                        let connOff = ivar_getOffset(connIvar)
                        let pipeRaw = Unmanaged.passUnretained(pipe).toOpaque()
                        let conn = pipeRaw.advanced(by: connOff)
                            .assumingMemoryBound(to: io_connect_t.self).pointee
                        var endpoint: UInt64 = 1
                        if let epIvar = class_getInstanceVariable(pipeCls, "_endpointAddress") {
                            let epOff = ivar_getOffset(epIvar)
                            endpoint = pipeRaw.advanced(by: epOff)
                                .assumingMemoryBound(to: UInt64.self).pointee
                        }
                        if conn != 0 {
                            handle.rawInterfaceConn = conn
                            handle.pipeEndpoint = endpoint
                            logger.info("IOUSBHost pipe conn extracted=0x\(String(conn, radix: 16)) ep=0x\(String(endpoint, radix: 16)) loc=\(locID)")
                        } else {
                            logger.warning("IOUSBHost pipe _ioConnection ivar = 0 loc=\(locID)")
                        }
                    } else {
                        logger.warning("IOUSBHost pipe _ioConnection ivar not found loc=\(locID)")
                    }
                }

                // IOUSBHOST_RING_TOKEN=1 : open a raw second-channel
                // user client on the parent IOUSBHostDevice service so
                // that writeRaw() can issue an inferred ring-drain
                // trigger (sel=10 with 13B frame-counter inStruct)
                // before each bulk write — matching the UsbDisplay
                // trace pattern. Type=1 is what IOUSBLib.bundle uses
                // (verified by disassembly of IOUSBDeviceClass::start
                // and IOUSBInterfaceClass::start at IOUSBLib offsets
                // 0x167c and 0x444c respectively).
                if ProcessInfo.processInfo.environment["IOUSBHOST_RING_TOKEN"] == "1" {
                    var devSvc: io_service_t = 0
                    let rcParent = IORegistryEntryGetParentEntry(service, kIOServicePlane, &devSvc)
                    if rcParent == KERN_SUCCESS, devSvc != 0 {
                        var conn: io_connect_t = 0
                        let rcOpen = IOServiceOpen(devSvc, mach_task_self_, 1, &conn)
                        if rcOpen == KERN_SUCCESS, conn != 0 {
                            // Run the same per-conn open prologue we
                            // see in IOKit-path traces: sel=0 (open
                            // with type=0). Without it, kernel returns
                            // kIOReturnBadArgument on later selectors.
                            let prereqOpen: [UInt64] = [0]
                            let rcSel0 = prereqOpen.withUnsafeBufferPointer { p in
                                IOConnectCallScalarMethod(
                                    conn, 0,
                                    p.baseAddress, 1,
                                    nil, nil
                                )
                            }
                            if rcSel0 != KERN_SUCCESS {
                                logger.warning("IOUSBHost raw DeviceUC sel=0 (open) failed rc=\(String(format: "0x%08X", rcSel0))")
                            }
                            handle.rawDeviceConn = conn
                            logger.info("IOUSBHost raw DeviceUC opened conn=0x\(String(conn, radix: 16)) loc=\(locID)")
                        } else {
                            logger.warning("IOUSBHost raw DeviceUC open failed rc=\(String(format: "0x%08X", rcOpen)) loc=\(locID)")
                        }
                        IOObjectRelease(devSvc)
                    }
                }

                devices.append(handle)
                opened += 1
                logger.info("IOUSBHost opened+unlocked device location=\(locID)")
            } catch {
                logger.warning("IOUSBHost open/unlock failed: \(error.localizedDescription)")
            }
        }

        guard !devices.isEmpty else {
            throw IOUSBHostTransportError.noMatchingDevices
        }
        logger.info("IOUSBHost connected to \(devices.count) matching device(s)")

        // Debug probe: when IOUSBHOST_PROBE_SELECTORS=1 is set, exercise a
        // handful of IOUSBHost APIs once so an attached lldb trace can map
        // them to IOConnectCallMethod selectors. Mapping discovered 2026-04-25:
        //   frameNumberWithTime          -> sel=7  (no scalar in)
        //   currentMicroframeWithTime    -> sel=8
        //   referenceMicroframeWithTime  -> sel=9
        //   setIdleTimeout (pipe)        -> sel=16 [pipeRef, timeoutMs]
        //   sendControlRequest           -> sel=2  (7 scalar args)
        //   sendIORequest    (pipe sync) -> sel=22 (4 scalar args)
        //   open / close                 -> sel=0 / sel=1
        // UsbDisplay's conn=0xb003 sel=10 (13B inStruct) and sel=34 (single
        // int) do NOT appear here — UsbDisplay reaches them through IOUSBLib
        // classic plug-in or raw IOConnectCallMethod. Identifying those two
        // requires sudo lldb attach to UsbDisplay itself.
        if ProcessInfo.processInfo.environment["IOUSBHOST_PROBE_SELECTORS"] == "1",
           let first = devices.first {
            let intf = first.interface
            var t1 = IOUSBHostTime()
            let fn = intf.__frameNumber(withTime: &t1)
            logger.info("[probe] frameNumberWithTime -> \(fn)")
            var t2 = IOUSBHostTime()
            var nserr: NSError?
            let mf = intf.__currentMicroframe(withTime: &t2, error: &nserr)
            logger.info("[probe] currentMicroframeWithTime -> \(mf)")
            var t3 = IOUSBHostTime()
            nserr = nil
            let rmf = intf.__referenceMicroframe(withTime: &t3, error: &nserr)
            logger.info("[probe] referenceMicroframeWithTime -> \(rmf)")
            try? first.bulkOut.setIdleTimeout(0.1)
            logger.info("[probe] pipe.setIdleTimeout 0.1s OK")
        }
        #else
        throw IOUSBHostTransportError.unsupported
        #endif
    }

    func disconnect() async {
        #if canImport(IOUSBHost)
        for h in devices where h.rawDeviceConn != 0 {
            IOServiceClose(h.rawDeviceConn)
            h.rawDeviceConn = 0
        }
        // rawInterfaceConn is borrowed from the framework (option 2 path);
        // closing it here would race the framework's own teardown.
        for h in devices { h.rawInterfaceConn = 0 }
        // IOUSBHost objects clean themselves up on dealloc.
        devices.removeAll()
        #endif
    }

    func deviceCount() async -> Int {
        #if canImport(IOUSBHost)
        return devices.count
        #else
        return 0
        #endif
    }

    func write(_ bytes: Data) async throws {
        #if canImport(IOUSBHost)
        for i in 0..<devices.count {
            try await writeRaw(deviceIndex: i, bytes: bytes)
        }
        #else
        throw IOUSBHostTransportError.unsupported
        #endif
    }

    func read(maxBytes: Int) async throws -> Data {
        return Data([ProtocolCommand.heartbeat.rawValue, 0, 0])
    }

    func writeRaw(deviceIndex: Int, bytes: Data) async throws {
        #if canImport(IOUSBHost)
        guard deviceIndex >= 0, deviceIndex < devices.count else {
            throw IOUSBHostTransportError.notConnected
        }
        let handle = devices[deviceIndex]

        emitRingTokenCounter(handle: handle)

        let mutable = NSMutableData(data: bytes)
        try await dispatchBulkWrite(handle: handle, mutable: mutable, originalLength: bytes.count, surfaceTag: nil)
        #else
        throw IOUSBHostTransportError.unsupported
        #endif
    }

    /// Surface-backed bulk write. The buffer handed to the framework
    /// (NSMutableData via bytesNoCopy) is the IOSurface's user-mapped
    /// base address. Hypothesis §17.4: the kernel-side IOMemoryDescriptor
    /// that __sendIORequest builds will see the surface's existing
    /// DMA-pinned mapping and skip the vm_map_wire step that anonymous
    /// heap buffers require — which is the suspected source of the
    /// 8 KB-per-session cap on this hardware/macOS combination.
    ///
    /// Also fills the sel=10 ring-token's first 4 bytes with the real
    /// IOSurfaceID (little-endian) instead of a synthetic counter, so
    /// the device sees the same metadata UsbDisplay sends.
    func writeRawSurface(deviceIndex: Int, surface: IOSurfaceRef, size: Int) async throws {
        #if canImport(IOUSBHost)
        guard deviceIndex >= 0, deviceIndex < devices.count else {
            throw IOUSBHostTransportError.notConnected
        }
        let handle = devices[deviceIndex]

        let csid = IOSurfaceGetID(surface)
        emitRingTokenForSurface(handle: handle, csid: csid)

        let lockOpts: IOSurfaceLockOptions = [.readOnly]
        let lockRc = IOSurfaceLock(surface, lockOpts, nil)
        guard lockRc == kIOReturnSuccess else {
            throw IOUSBHostTransportError.writeFailed("IOSurfaceLock rc=\(String(format: "0x%08X", lockRc))")
        }
        defer { IOSurfaceUnlock(surface, lockOpts, nil) }

        let baseAddr = IOSurfaceGetBaseAddress(surface)
        let allocSize = IOSurfaceGetAllocSize(surface)
        let length = min(size, allocSize)

        // NSMutableData wrapping the surface's user-mapped base without
        // copy. freeWhenDone=false because the surface owns the storage
        // — release happens on IOSurfaceUnlock and ref drop.
        let mutable = NSMutableData(bytesNoCopy: baseAddr, length: length, freeWhenDone: false)
        let surfaceTag = "csid=0x\(String(csid, radix: 16)) allocSize=\(allocSize)"
        try await dispatchBulkWrite(handle: handle, mutable: mutable, originalLength: length, surfaceTag: surfaceTag)
        #else
        throw IOUSBHostTransportError.unsupported
        #endif
    }

    #if canImport(IOUSBHost)
    /// Synthetic ring-token (counter + 12 zeros). Used by writeRaw,
    /// where no IOSurface context is available — matches the legacy
    /// inferred shape from early lldb traces.
    private func emitRingTokenCounter(handle: IOUSBHostDeviceHandle) {
        guard handle.rawDeviceConn != 0 else { return }
        var token = [UInt8](repeating: 0, count: 13)
        token[0] = handle.ringTokenCounter
        handle.ringTokenCounter = handle.ringTokenCounter &+ 1
        let rc = token.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> kern_return_t in
            IOConnectCallMethod(handle.rawDeviceConn, 10,
                                nil, 0,
                                raw.baseAddress, raw.count,
                                nil, nil, nil, nil)
        }
        if rc != KERN_SUCCESS {
            logger.warning("IOUSBHost ring-token (counter) sel=10 failed rc=\(String(format: "0x%08X", rc)) loc=\(handle.locationID)")
        }
    }

    /// Surface-aware ring-token: real csid (UInt32 LE) + 9 zero bytes.
    /// Matches UsbDisplay's exact payload shape — see HANDOFF §17.3 (2).
    private func emitRingTokenForSurface(handle: IOUSBHostDeviceHandle, csid: UInt32) {
        guard handle.rawDeviceConn != 0 else { return }
        var token = [UInt8](repeating: 0, count: 13)
        var leCsid = csid.littleEndian
        withUnsafeBytes(of: &leCsid) { src in
            for i in 0..<4 { token[i] = src[i] }
        }
        let rc = token.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> kern_return_t in
            IOConnectCallMethod(handle.rawDeviceConn, 10,
                                nil, 0,
                                raw.baseAddress, raw.count,
                                nil, nil, nil, nil)
        }
        if rc != KERN_SUCCESS {
            logger.warning("IOUSBHost ring-token (csid=0x\(String(csid, radix: 16))) sel=10 failed rc=\(String(format: "0x%08X", rc)) loc=\(handle.locationID)")
        }
    }

    /// Common bulk dispatch path used by both writeRaw and writeRawSurface.
    /// Branch selection (useRaw / useAsync / default framework) is identical
    /// — only the NSMutableData backing differs between callers.
    private func dispatchBulkWrite(handle: IOUSBHostDeviceHandle, mutable: NSMutableData, originalLength: Int, surfaceTag: String?) async throws {
        var transferred = 0
        let useRaw = ProcessInfo.processInfo.environment["IOUSBHOST_RAW_BULK"] == "1"
            && handle.rawInterfaceConn != 0
        let useAsync = ProcessInfo.processInfo.environment["IOUSBHOST_ASYNC"] == "1"
        let tag = surfaceTag.map { " surface[\($0)]" } ?? ""
        do {
            if useRaw {
                let bufPtr = mutable.bytes
                let scalars: [UInt64] = [
                    handle.pipeEndpoint, 0, 500, 500,
                    UInt64(UInt(bitPattern: bufPtr)),
                    UInt64(mutable.length),
                    1,
                ]
                let rc = scalars.withUnsafeBufferPointer { sp -> kern_return_t in
                    IOConnectCallMethod(handle.rawInterfaceConn, 7,
                                        sp.baseAddress, 7,
                                        bufPtr, mutable.length,
                                        nil, nil, nil, nil)
                }
                if rc != KERN_SUCCESS {
                    throw IOUSBHostTransportError.writeFailed("raw sel=7 rc=\(String(format: "0x%08X", rc))")
                }
                transferred = mutable.length
            } else if useAsync {
                transferred = try await enqueueAndWait(handle: handle, data: mutable)
            } else {
                try handle.bulkOut.__sendIORequest(
                    with: mutable,
                    bytesTransferred: &transferred,
                    completionTimeout: 0.5
                )
            }
            logger.info("IOUSBHost bulk write OK loc=\(handle.locationID) sent=\(transferred)/\(originalLength) raw=\(useRaw) async=\(useAsync)\(tag)")
        } catch {
            logger.warning("IOUSBHost bulk write FAILED loc=\(handle.locationID) sent=\(transferred)/\(originalLength) err=\(error.localizedDescription) raw=\(useRaw) async=\(useAsync)\(tag)")
            throw IOUSBHostTransportError.writeFailed(error.localizedDescription)
        }
    }
    #endif

    #if canImport(IOUSBHost)
    private func enqueueAndWait(handle: IOUSBHostDeviceHandle, data: NSMutableData) async throws -> Int {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            let handler: @Sendable (IOReturn, Int) -> Void = { status, transferred in
                if status == kIOReturnSuccess {
                    cont.resume(returning: transferred)
                } else {
                    let hex = String(format: "0x%08X", UInt32(bitPattern: status))
                    cont.resume(throwing: IOUSBHostTransportError.writeFailed("IOReturn=\(hex)"))
                }
            }
            do {
                try handle.bulkOut.enqueueIORequest(
                    with: data,
                    completionTimeout: 0.5,
                    completionHandler: handler
                )
            } catch {
                cont.resume(throwing: error)
            }
        }
    }
    #endif

    func vendorOut(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, payload: Data) async throws -> Bool {
        #if canImport(IOUSBHost)
        guard deviceIndex >= 0, deviceIndex < devices.count else {
            throw IOUSBHostTransportError.notConnected
        }
        let handle = devices[deviceIndex]
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x41
        req.bRequest = bRequest
        req.wValue = wValue
        req.wIndex = 0
        req.wLength = UInt16(payload.count)
        let mutable = payload.isEmpty ? nil : NSMutableData(data: payload)
        var transferred = 0
        do {
            try handle.interface.__send(
                req,
                data: mutable,
                bytesTransferred: &transferred,
                completionTimeout: 0.5
            )
            return true
        } catch {
            logger.warning("IOUSBHost vendor OUT bReq=\(String(format: "0x%02X", bRequest)) wVal=\(wValue) failed: \(error.localizedDescription)")
            return false
        }
        #else
        throw IOUSBHostTransportError.unsupported
        #endif
    }

    func vendorIn(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, wLength: UInt16) async throws -> Data? {
        #if canImport(IOUSBHost)
        guard deviceIndex >= 0, deviceIndex < devices.count else {
            throw IOUSBHostTransportError.notConnected
        }
        let handle = devices[deviceIndex]
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0xC1
        req.bRequest = bRequest
        req.wValue = wValue
        req.wIndex = 0
        req.wLength = wLength
        let mutable = NSMutableData(length: Int(wLength))!
        var transferred = 0
        do {
            try handle.interface.__send(
                req,
                data: mutable,
                bytesTransferred: &transferred,
                completionTimeout: 0.5
            )
            return mutable.subdata(with: NSRange(location: 0, length: transferred))
        } catch {
            return nil
        }
        #else
        throw IOUSBHostTransportError.unsupported
        #endif
    }

    func clearHalt(deviceIndex: Int) async throws {
        #if canImport(IOUSBHost)
        guard deviceIndex >= 0, deviceIndex < devices.count else {
            throw IOUSBHostTransportError.notConnected
        }
        let handle = devices[deviceIndex]
        // IOUSBHostPipe inherits clearStall from IOUSBHostIOSource.
        try? handle.bulkOut.clearStall()
        #else
        throw IOUSBHostTransportError.unsupported
        #endif
    }

    #if canImport(IOUSBHost)
    private func runUnlockSequence(handle: IOUSBHostDeviceHandle) async throws {
        // IN reads
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
        for (bReq, wVal, wLen) in initReads {
            var req = IOUSBDeviceRequest()
            req.bmRequestType = 0xC1
            req.bRequest = bReq
            req.wValue = wVal
            req.wIndex = 0
            req.wLength = wLen
            let buf = NSMutableData(length: Int(wLen))!
            var n = 0
            _ = try? handle.interface.__send(req, data: buf, bytesTransferred: &n, completionTimeout: 0.5)
        }

        // DQT (138B): bReq=0x83 wValue=1
        let dqt = NSMutableData(bytes: LibUSBTransport.bulkUnlockDQT, length: LibUSBTransport.bulkUnlockDQT.count)
        var dqtReq = IOUSBDeviceRequest()
        dqtReq.bmRequestType = 0x41
        dqtReq.bRequest = 0x83
        dqtReq.wValue = 1
        dqtReq.wIndex = 0
        dqtReq.wLength = UInt16(dqt.length)
        var n = 0
        do {
            try handle.interface.__send(dqtReq, data: dqt, bytesTransferred: &n, completionTimeout: 0.5)
        } catch {
            throw IOUSBHostTransportError.unlockFailed("DQT: \(error.localizedDescription)")
        }

        // SetResolution 1920x1200 — sent twice as the original app does.
        let resBytes: [UInt8] = [0x80, 0x07, 0xb0, 0x04]
        let resData = NSMutableData(bytes: resBytes, length: 4)
        var resReq = IOUSBDeviceRequest()
        resReq.bmRequestType = 0x41
        resReq.bRequest = 0x81
        resReq.wValue = 0
        resReq.wIndex = 0
        resReq.wLength = 4
        for i in 0..<2 {
            do {
                try handle.interface.__send(resReq, data: resData, bytesTransferred: &n, completionTimeout: 0.5)
            } catch {
                throw IOUSBHostTransportError.unlockFailed("SetResolution#\(i+1): \(error.localizedDescription)")
            }
        }
    }
    #endif
}

private extension io_service_t {
    func locationIDHex() throws -> String {
        let key = "locationID" as CFString
        guard let cf = IORegistryEntryCreateCFProperty(self, key, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return "?"
        }
        if let n = cf as? NSNumber {
            return String(format: "0x%X", n.uint32Value)
        }
        return "?"
    }
}
