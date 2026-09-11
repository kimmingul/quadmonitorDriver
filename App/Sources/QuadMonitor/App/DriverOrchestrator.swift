import Foundation
import IOSurface
import CoreGraphics
import CoreVideo
import CoreMedia
#if canImport(ScreenCaptureKit)
import ScreenCaptureKit
#endif
#if canImport(CIOKitUSB)
import CIOKitUSB
#endif

actor DriverOrchestrator {
    private let config: DriverConfiguration
    private let usbManager: USBManager
    private let displayManager: DisplayManager
    private let powerManager: PowerManager
    private let videoPipeline: VideoPipeline
    private let logger: Logger
    private let runtimeMetrics: RuntimeMetrics

    init(
        config: DriverConfiguration,
        usbManager: USBManager,
        displayManager: DisplayManager,
        powerManager: PowerManager,
        videoPipeline: VideoPipeline,
        logger: Logger,
        runtimeMetrics: RuntimeMetrics
    ) {
        self.config = config
        self.usbManager = usbManager
        self.displayManager = displayManager
        self.powerManager = powerManager
        self.videoPipeline = videoPipeline
        self.logger = logger
        self.runtimeMetrics = runtimeMetrics
    }

    func start() async {
        do {
            let fps = await powerManager.recommendedTargetFPS(baseFPS: config.targetFPS)
            await displayManager.configureDefaultDisplays(count: config.monitorCount, targetFPS: fps)
            await videoPipeline.logPipelineReady()

            try await usbManager.connect()
            logger.info("Stage: usb connect complete")

            if config.probeOnly {
                let probe = ProtocolProbe(usbManager: usbManager, logger: logger)
                let upperBound = UInt8(min(255, config.probeLimit - 1))
                await probe.runCommandByteSweep(range: 0x00...upperBound)
                logger.info("Probe-only mode complete")
                return
            }

            if let framesDir = config.replayFramesDir {
                try await runReplayFramesMode(dir: framesDir)
                return
            }

            if let streamPath = config.streamFramePath {
                try await runStreamFrameMode(path: streamPath)
                return
            }

            if let replayPath = config.replayFilePath {
                try await runReplayFileMode(path: replayPath, chunk: config.replayChunk)
                return
            }

            if let probeSize = config.bulkProbeSize {
                try await runBulkProbeMode(size: probeSize)
                return
            }

            if config.testFrame {
                try await runTestFrameMode()
                return
            }

            try await usbManager.initializeDevice()
            logger.info("Stage: device initialization packet complete")

            let targets = await displayManager.targets
            for target in targets {
                try await usbManager.setDisplayMode(displayIndex: target.index, mode: target.mode)
            }
            logger.info("Stage: display mode packets complete")

            // Keep initial run short and deterministic; this is upgraded to a continuous loop
            // once real hardware protocol validation is completed.
            let frameIntervalNs = UInt64(1_000_000_000 / max(1, fps))
            for frameNumber in 0..<120 {
                let start = DispatchTime.now().uptimeNanoseconds

                for target in targets {
                    let frame = await videoPipeline.encodeSyntheticFrame(
                        displayIndex: target.index,
                        frameNumber: UInt64(frameNumber)
                    )
                    try await usbManager.sendFrame(frame)
                }
                try await usbManager.heartbeat()

                let elapsedNs = DispatchTime.now().uptimeNanoseconds - start
                await runtimeMetrics.recordFrameDuration(Double(elapsedNs) / 1_000_000.0)

                if elapsedNs < frameIntervalNs {
                    try await Task.sleep(nanoseconds: frameIntervalNs - elapsedNs)
                }
            }

            logger.info("Runtime metrics: \(await runtimeMetrics.summary())")
            logger.info("Bootstrap run completed successfully")
        } catch {
            logger.error("Driver startup failed: \(error.localizedDescription)")
            PermissionAdvisor.reportStartupFailure(error, config: config, logger: logger)
        }

        await usbManager.disconnect()
    }

    /// Stage A — push a static 1920×1200 JPEG to each opened USB unit.
    /// Visual confirmation: each monitor should show its color-coded test
    /// pattern (display 0 = red, 1 = green, 2 = blue).
    /// SAFETY: one bulk write per device per run, no retries.
    private func runTestFrameMode() async throws {
        let count = await usbManager.deviceCount()
        guard count > 0 else {
            logger.warning("Test-frame mode: no devices opened")
            return
        }

        let generator = JPEGTestFrame(dqtMarker: LibUSBTransport.bulkUnlockDQT)
        logger.info("Test-frame mode: \(count) device(s) opened, sending one JPEG each")

        for i in 0..<count {
            guard let frame = generator.encode(displayIndex: i) else {
                logger.warning("device \(i): JPEG encode returned nil — skipping")
                continue
            }
            do {
                try await usbManager.sendRawToDevice(index: i, bytes: frame)
                logger.info("device \(i): frame sent OK (\(frame.count) bytes)")
            } catch {
                logger.warning("device \(i): frame failed (\(frame.count) bytes) — \(error.localizedDescription)")
            }
        }
    }

    /// Diagnostic — bulk OUT of `size` bytes, repeated `bulkProbeCount` times,
    /// to device 0 only. Per-iteration result is logged so the firmware's
    /// 16-packet ring behavior is observable. Optional sleep, vendor IN
    /// heartbeat, or clear_halt between iterations to test ring-drain
    /// hypotheses. No retries, no broadcast — designed to be safe.
    /// E2-continuation: replay a captured vendor frame to device 0 as a sequence
    /// of `chunk`-byte bulk writes (advancing through the file), reproducing the
    /// vendor's many-small-writes pattern. Each write < a 512-multiple ends with
    /// a short packet. Logs cumulative bytes accepted; stops at the first stall.
    /// Tests whether conformant data delivered in vendor-sized chunks drains the
    /// ring past the 16384 monolithic-write ceiling.
    /// E3': replay a directory of complete vendor frames (frame_*.bin), each as
    /// ONE bulk write ending in its natural short packet, in sorted order, looped
    /// `replayLoops` times. Tests whether streaming complete 0xD0-framed frames
    /// lets the firmware decoder drain its ring between frames — sustaining
    /// cumulative bytes far past the 16384 cold-start ceiling. Frames larger than
    /// `replayMaxBytes` (when >0) are skipped so we can prime with small frames.
    private func runReplayFramesMode(dir: String) async throws {
        let count = await usbManager.deviceCount()
        guard count > 0 else {
            logger.warning("Replay-frames mode: no devices opened")
            return
        }
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: dir))?
            .filter { ($0.hasPrefix("frame_") || $0.hasPrefix("coldframe_")) && $0.hasSuffix(".bin") }
            .sorted() ?? []
        guard !names.isEmpty else {
            logger.error("Replay-frames: no frame_*.bin in \(dir)")
            return
        }
        let maxBytes = config.replayMaxBytes
        let loops = config.replayLoops
        let delay = config.bulkProbeDelayMs
        logger.info("Replay-frames: device 0, dir=\(dir) frames=\(names.count) maxBytes=\(maxBytes) loops=\(loops) delay=\(delay)ms")

        var cumulative = 0
        var sent = 0
        for loop in 0..<loops {
            for name in names {
                let url = URL(fileURLWithPath: dir).appendingPathComponent(name)
                guard let frame = try? Data(contentsOf: url), !frame.isEmpty else { continue }
                if maxBytes > 0, frame.count > maxBytes { continue }
                do {
                    try await usbManager.sendRawToDevice(index: 0, bytes: frame)
                    cumulative += frame.count
                    sent += 1
                    logger.info("Replay-frames loop=\(loop) \(name) size=\(frame.count) OK cumulative=\(cumulative) sent=\(sent)")
                } catch {
                    logger.warning("Replay-frames loop=\(loop) \(name) size=\(frame.count) FAILED at cumulative=\(cumulative) sent=\(sent) — \(error.localizedDescription)")
                    return
                }
                // Vendor polls bReq=0x49 (G-sensor/status) at ~22Hz during
                // streaming — candidate per-frame "processed, send next"
                // handshake that drains the firmware ring. --bulk-heartbeat-between.
                if config.bulkProbeHeartbeatBetween {
                    if let r = try? await usbManager.vendorIn(deviceIndex: 0, bRequest: 0x49, wValue: 0, wLength: 1) {
                        logger.info("Replay-frames \(name) heartbeat0x49=\(r.map { String(format: "%02X", $0) }.joined())")
                    }
                }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)
                }
            }
        }
        logger.info("Replay-frames COMPLETE: \(sent) frames, \(cumulative)B accepted (ceiling 16384 \(cumulative > 16384 ? "BROKEN" : "not exceeded"))")
    }

    /// Step C1 — stream ONE pre-encoded 0xD0 frame to device 0 continuously at
    /// `targetFPS`, recovering from a stall (clearHalt) and continuing instead of
    /// aborting on the first failure like replay-frames does. This is the cheapest
    /// decisive test of the remaining unknown: the encoder is proven byte-exact
    /// and the device drains our bytes, but a single static frame never presented
    /// on the panel. If the device double-buffers (presenting frame N when frame
    /// N+1 begins), a *sustained* stream is what makes it scan out. We log frames
    /// sent / stalls / cumulative each second so ring-drain sustainment is visible.
    private func runStreamFrameMode(path: String) async throws {
        let count = await usbManager.deviceCount()
        guard count > 0 else {
            logger.warning("Stream-frame: no devices opened")
            return
        }
        let frame = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !frame.isEmpty else {
            logger.error("Stream-frame: \(path) is empty")
            return
        }

        // Hypothesis Q': drive ALL displays concurrently (libusb async) — the
        // firmware may only drain a ring while its sibling displays are also
        // being written. This is the vendor's actual pattern (3 monitors at once).
        if config.streamAllDevices {
            let secs = config.streamSeconds == 0 ? 3600 : config.streamSeconds
            let ok = await usbManager.streamAllDevicesAsync(frame: [UInt8](frame), seconds: secs)
            if !ok { logger.warning("Stream-all: requires libusb transport — falling back to single-device") ; }
            if ok { return }
        }
        let fps = max(1, config.targetFPS)
        let frameIntervalNs = UInt64(1_000_000_000 / fps)
        let runForever = config.streamSeconds == 0
        let startNs = DispatchTime.now().uptimeNanoseconds
        let deadlineNs = startNs &+ UInt64(config.streamSeconds) &* 1_000_000_000
        logger.info("Stream-frame: device 0, file=\(path) size=\(frame.count) fps=\(fps) seconds=\(runForever ? "∞" : String(config.streamSeconds)) heartbeat=\(config.bulkProbeHeartbeatBetween)")

        var frames = 0
        var stalls = 0
        var cumulative = 0
        var lastLogNs = startNs
        while runForever || DispatchTime.now().uptimeNanoseconds < deadlineNs {
            let iterStart = DispatchTime.now().uptimeNanoseconds
            do {
                try await usbManager.sendRawToDevice(index: 0, bytes: frame)
                frames += 1
                cumulative += frame.count
            } catch {
                stalls += 1
                // Recover the host-side pipe stall and keep streaming.
                try? await usbManager.clearHalt(deviceIndex: 0)
            }
            // Optional vendor 0x49 poll — the cadence the vendor keeps during
            // streaming; candidate ring-drain / present handshake.
            if config.bulkProbeHeartbeatBetween {
                _ = try? await usbManager.vendorIn(deviceIndex: 0, bRequest: 0x49, wValue: 0, wLength: 1)
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if now &- lastLogNs > 1_000_000_000 {
                let secs = Double(now &- startNs) / 1_000_000_000
                logger.info(String(format: "Stream-frame t+%.1fs frames=%d stalls=%d cumulative=%d (%.1f MB, ~%.0ffps)",
                                   secs, frames, stalls, cumulative, Double(cumulative)/1_048_576, Double(frames)/max(secs, 0.001)))
                lastLogNs = now
            }
            let elapsed = DispatchTime.now().uptimeNanoseconds &- iterStart
            if elapsed < frameIntervalNs {
                try? await Task.sleep(nanoseconds: frameIntervalNs - elapsed)
            }
        }
        logger.info("Stream-frame COMPLETE: frames=\(frames) stalls=\(stalls) cumulative=\(cumulative)B")
    }

    private func runReplayFileMode(path: String, chunk: Int) async throws {
        let count = await usbManager.deviceCount()
        guard count > 0 else {
            logger.warning("Replay mode: no devices opened")
            return
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty else {
            logger.error("Replay file \(path) is empty")
            return
        }
        let delay = config.bulkProbeDelayMs
        logger.info("Replay: device 0, file=\(path) total=\(data.count)B chunk=\(chunk) delay=\(delay)ms (\((data.count + chunk - 1) / chunk) writes)")

        var offset = 0
        var cumulative = 0
        var index = 0
        while offset < data.count {
            let end = min(offset + chunk, data.count)
            let slice = data.subdata(in: offset..<end)
            do {
                try await usbManager.sendRawToDevice(index: 0, bytes: slice)
                cumulative += slice.count
                logger.info("Replay chunk \(index) off=\(offset) size=\(slice.count) OK cumulative=\(cumulative)")
            } catch {
                logger.warning("Replay chunk \(index) off=\(offset) size=\(slice.count) FAILED at cumulative=\(cumulative) — \(error.localizedDescription)")
                return
            }
            offset = end
            index += 1
            if offset < data.count, delay > 0 {
                try? await Task.sleep(nanoseconds: delay * 1_000_000)
            }
        }
        logger.info("Replay COMPLETE: all \(cumulative)B of \(data.count)B accepted across \(index) writes")
    }

    private func runBulkProbeMode(size: Int) async throws {
        let count = await usbManager.deviceCount()
        guard count > 0 else {
            logger.warning("Bulk-probe mode: no devices opened")
            return
        }

        let iterations = max(1, config.bulkProbeCount)
        let delay = config.bulkProbeDelayMs
        let heartbeat = config.bulkProbeHeartbeatBetween
        let clearHaltBetween = config.bulkProbeClearHaltBetween

        // IOSURFACE_PROBE=1 → buffer backed by IOSurface (kernel-allocated,
        // already DMA-mappable / wired). Hypothesis H: UsbDisplay's 825K cap
        // works because its buffer is the IOSurface base address handed in
        // by CGDisplayStream/SCStream — kernel maps it as a single contiguous
        // DMA segment. Regular process memory (Data) gets per-transfer
        // lock+map, racing the device ring at the 16-packet (8K) boundary.
        //
        // SCREEN_PROBE=1 → buffer is the IOSurface output by a live
        // CGDisplayStream callback (display-bound surface). UsbDisplay's
        // path. Tests whether GPU/display mediation specifically (not just
        // any IOSurface) is what bypasses the 8K cap.
        let useIOSurface = ProcessInfo.processInfo.environment["IOSURFACE_PROBE"] == "1"
        let useScreenProbe = ProcessInfo.processInfo.environment["SCREEN_PROBE"] == "1"
        let useSCStreamProbe = ProcessInfo.processInfo.environment["SCSTREAM_PROBE"] == "1"
        let useSCStreamDispatchProbe = ProcessInfo.processInfo.environment["SCSTREAM_DISPATCH_PROBE"] == "1"

        // SCSTREAM_DISPATCH_PROBE: write happens INSIDE the SCStream callback
        // — same libdispatch/CMCapture context as UsbDisplay's 825K writes
        // (verified via lldb stack trace 2026-04-26 session #3). The other
        // SCStream variants only borrow the IOSurface; they leave the actual
        // WritePipe call on the actor thread, missing the dispatch context.
        if useSCStreamDispatchProbe {
            #if canImport(CIOKitUSB)
            if #available(macOS 12.3, *) {
                let devBits = await usbManager.rawIOKitDevicePointerBits(at: 0)
                guard devBits != 0, let dev = OpaquePointer(bitPattern: devBits) else {
                    logger.error("Bulk-probe: SCSTREAM_DISPATCH_PROBE — no IOKit device 0")
                    return
                }
                let collector = SCStreamDispatchProbeCollector(device: dev, size: size)
                let rc = await runSCStreamDispatchProbe(collector: collector, timeoutSeconds: 6.0)
                if rc == 0 {
                    logger.info("Bulk-probe: SCSTREAM_DISPATCH_PROBE \(size)B OK")
                } else if rc == Int32.min {
                    logger.warning("Bulk-probe: SCSTREAM_DISPATCH_PROBE timed out (no frame)")
                } else {
                    logger.warning("Bulk-probe: SCSTREAM_DISPATCH_PROBE \(size)B FAILED rc=0x\(String(format: "%X", UInt32(bitPattern: rc)))")
                }
                return
            } else {
                logger.error("Bulk-probe: SCSTREAM_DISPATCH_PROBE requires macOS 12.3+")
                return
            }
            #else
            logger.error("Bulk-probe: SCSTREAM_DISPATCH_PROBE requires IOKit transport")
            return
            #endif
        }
        var iosurfaceHolder: IOSurfaceRef? = nil
        if useSCStreamProbe {
            // Modern path: SCStream → CMCapture pipeline → IOSurface. UsbDisplay
            // launch trace stack proves this is the dispatch context for its
            // 825K bulk writes. CGDisplayStream is deprecated and uses a
            // different internal mediator that does not engage CMCapture.
            if #available(macOS 12.3, *) {
                iosurfaceHolder = await captureSCStreamSurface(timeoutSeconds: 5.0)
                if let s = iosurfaceHolder {
                    IOSurfaceLock(s, [], nil)
                    let base = IOSurfaceGetBaseAddress(s)
                    base.initializeMemory(as: UInt8.self, repeating: 0x55, count: size)
                    logger.info("Bulk-probe: SCSTREAM_PROBE captured SCStream IOSurface (CMCapture-mediated) size=\(size)")
                } else {
                    logger.error("Bulk-probe: SCSTREAM_PROBE failed (Screen Recording permission?)")
                    return
                }
            } else {
                logger.error("Bulk-probe: SCSTREAM_PROBE requires macOS 12.3+")
                return
            }
        } else if useScreenProbe {
            iosurfaceHolder = captureDisplayStreamSurface(timeoutSeconds: 5.0)
            if let s = iosurfaceHolder {
                IOSurfaceLock(s, [], nil)
                let base = IOSurfaceGetBaseAddress(s)
                base.initializeMemory(as: UInt8.self, repeating: 0x55, count: size)
                logger.info("Bulk-probe: SCREEN_PROBE captured CGDisplayStream IOSurface (display-bound) size=\(size)")
            } else {
                logger.error("Bulk-probe: SCREEN_PROBE failed to capture display surface (Screen Recording permission?)")
                return
            }
        } else if useIOSurface {
            // Graphics-aware IOSurface: BGRA pixel format, write-combine
            // cache mode (kIOMapWriteCombineCache=4), full 1920×1200×4
            // surface allocated (matches UsbDisplay's frame buffer geometry).
            // We write into the first `size` bytes only. Hypothesis H'':
            // GPU-mappable surface (without needing actual display binding)
            // is what flips the kernel into unrestricted-DMA mode.
            let frameW = 1920
            let frameH = 1200
            let bpe = 4
            let pixelFormat = Int(0x42475241)  // 'BGRA'
            let dict: [IOSurfacePropertyKey: Any] = [
                .width: frameW,
                .height: frameH,
                .bytesPerElement: bpe,
                .bytesPerRow: frameW * bpe,
                .pixelFormat: pixelFormat,
                .cacheMode: 4,  // kIOMapWriteCombineCache
            ]
            guard let s = IOSurfaceCreate(dict as CFDictionary) else {
                logger.error("Bulk-probe: IOSurfaceCreate failed for size=\(size)")
                return
            }
            iosurfaceHolder = s
            IOSurfaceLock(s, [], nil)
            let base = IOSurfaceGetBaseAddress(s)
            base.initializeMemory(as: UInt8.self, repeating: 0x55, count: size)
            logger.info("Bulk-probe: graphics-aware IOSurface (BGRA, write-combine, \(frameW)×\(frameH)) allocated, using first \(size)B")
        }

        var payloadDescription = useIOSurface ? "0x55-fill (IOSurface)" : "0x55-fill"
        var buf: Data
        if let path = config.bulkProbePayloadPath {
            let url = URL(fileURLWithPath: path)
            let payload = try Data(contentsOf: url)
            guard !payload.isEmpty else {
                logger.error("Bulk-probe payload \(path) is empty")
                return
            }
            var tiled = Data(capacity: size)
            while tiled.count < size {
                let take = min(payload.count, size - tiled.count)
                tiled.append(payload.prefix(take))
            }
            buf = tiled
            payloadDescription = "payload=\(path) (\(payload.count)B tiled to \(size)B)"
        } else if let s = iosurfaceHolder {
            // Wrap IOSurface base address as Data without copying — buffer
            // is owned by the IOSurfaceRef and stays valid until unlock+release.
            let base = IOSurfaceGetBaseAddress(s)
            buf = Data(bytesNoCopy: base, count: size, deallocator: .none)
        } else {
            buf = Data(repeating: 0x55, count: size)
        }
        logger.info(
            "Bulk-probe: device 0, count=\(iterations) size=\(size) delay=\(delay)ms heartbeat-between=\(heartbeat) clear-halt-between=\(clearHaltBetween) content=\(payloadDescription)"
        )

        // Hypothesis Q / Q': other-device USB traffic triggers the firmware
        // bulk-OUT ring drain. cap1b (UsbDisplay success) had DISP×3 + Hub
        // + sniffer all active; cap2 (our fail) had only Dev=4 active.
        // OTHER_DEV_POLL=1 spins a background Thread that pokes the other
        // 2 devices at OTHER_DEV_POLL_INTERVAL_MS (default 45ms ~= 22Hz),
        // bypassing the actor so polling runs concurrently with the blocked
        // bulk_transfer.
        //
        // OTHER_DEV_POLL_MODE selects the traffic shape:
        //   control (default) — vendor IN bReq=0x49. Falsified by cap3.
        //   bulk              — 512 B bulk OUT to other devices' ep=0x01.
        //                       Matches cap1b's traffic shape (Q' test).
        let env = ProcessInfo.processInfo.environment
        let otherDevPoll = env["OTHER_DEV_POLL"] == "1"
        let pollIntervalMs: UInt32 = {
            if let s = env["OTHER_DEV_POLL_INTERVAL_MS"], let v = UInt32(s), v > 0 { return v }
            return 45
        }()
        let pollMode: LibUSBHeartbeatPoller.Mode = {
            if env["OTHER_DEV_POLL_MODE"] == "bulk" { return .bulk }
            return .control
        }()
        if otherDevPoll {
            let started = await usbManager.startOtherDeviceHeartbeatPolling(
                skipIndex: 0,
                intervalMs: pollIntervalMs,
                mode: pollMode
            )
            if started {
                logger.info("Bulk-probe: OTHER_DEV_POLL=1 mode=\(pollMode) interval=\(pollIntervalMs)ms (hypothesis Q/Q')")
            }
        }
        // SAME_DEV_POLL=1 — poll device 0's OWN control IN (0x49) concurrently
        // during its bulk write, from a dedicated thread. Mirrors the vendor's
        // async-bulk + concurrent same-device control-poll pattern (cold-start
        // trace 2026-06-28: 0x49 ×188, 0x40 ×48 during streaming). Tests whether
        // an in-flight control read drains the firmware ring past 16384.
        let sameDevPoll = env["SAME_DEV_POLL"] == "1"
        if sameDevPoll {
            let started = await usbManager.startSameDeviceHeartbeatPolling(
                index: 0,
                intervalMs: pollIntervalMs,
                mode: pollMode
            )
            if started {
                logger.info("Bulk-probe: SAME_DEV_POLL=1 mode=\(pollMode) interval=\(pollIntervalMs)ms (same-device concurrent poll)")
            }
        }
        // READPIPE_PROBE=before|after|both — issue ReadPipeTO(pipeRef=1)
        // around every bulk OUT. Mirrors UsbDisplay fn_100015c64's recovery
        // pattern (SetPipePolicy + sleep(0) + ReadPipe on WritePipeTO error
        // 0xE000_404F). Tests whether driving the pipe in both directions
        // pokes the firmware into draining its 16-packet ring. IOKit
        // transport only — silently no-ops on libusb/IOUSBHost.
        let readProbeMode = env["READPIPE_PROBE"] ?? ""
        let readProbeBefore = readProbeMode == "before" || readProbeMode == "both"
        let readProbeAfter = readProbeMode == "after" || readProbeMode == "both"
        let readProbeSize: Int = {
            if let s = env["READPIPE_PROBE_SIZE"], let v = Int(s), v > 0 { return v }
            return 64
        }()
        if readProbeBefore || readProbeAfter {
            logger.info("Bulk-probe: READPIPE_PROBE=\(readProbeMode) size=\(readProbeSize) (fn_100015c64 mimic)")
        }

        // IOUSBHOST_SURFACE_WRITE=1 (hypothesis §17.4): when an IOSurface is
        // available, hand its user-mapped base address straight to the
        // IOUSBHost framework via NSMutableData(bytesNoCopy:) — the same
        // buffer-backing path UsbDisplay uses. Requires --use-iousbhost and
        // one of SCSTREAM_PROBE / SCREEN_PROBE / IOSURFACE_PROBE (so we have
        // a surface to wrap). Falls back to the regular Data-byte path when
        // either condition is missing.
        let useSurfaceWrite = env["IOUSBHOST_SURFACE_WRITE"] == "1" && iosurfaceHolder != nil
        if useSurfaceWrite {
            logger.info("Bulk-probe: IOUSBHOST_SURFACE_WRITE=1 — using surface-backed NSMutableData(bytesNoCopy:) path")
        }

        var cumulativeOk = 0
        for i in 0..<iterations {
            if readProbeBefore {
                if let r = await usbManager.bulkReadProbe(index: 0, pipeRef: 1, size: readProbeSize) {
                    logger.info("Bulk-probe iter=\(i) pre-ReadPipe rc=0x\(String(format: "%X", UInt32(bitPattern: r.rc))) got=\(r.transferred)")
                }
            }
            var writeFailed = false
            do {
                if useSurfaceWrite, let s = iosurfaceHolder {
                    let ok = try await usbManager.sendRawSurfaceToDevice(index: 0, surface: SendableSurface(s), size: size)
                    if !ok {
                        logger.warning("Bulk-probe iter=\(i) surface path unavailable (transport not IOUSBHost) — falling back to bytes")
                        try await usbManager.sendRawToDevice(index: 0, bytes: buf)
                    }
                } else {
                    try await usbManager.sendRawToDevice(index: 0, bytes: buf)
                }
                cumulativeOk += size
                logger.info("Bulk-probe iter=\(i) \(size)B OK cumulativeOk=\(cumulativeOk)")
            } catch {
                logger.warning("Bulk-probe iter=\(i) \(size)B FAILED — \(error.localizedDescription)")
                writeFailed = true
            }

            if readProbeAfter {
                if let r = await usbManager.bulkReadProbe(index: 0, pipeRef: 1, size: readProbeSize) {
                    logger.info("Bulk-probe iter=\(i) post-ReadPipe rc=0x\(String(format: "%X", UInt32(bitPattern: r.rc))) got=\(r.transferred)")
                }
            }
            if writeFailed { break }

            if i < iterations - 1 {
                if clearHaltBetween {
                    try? await usbManager.clearHalt(deviceIndex: 0)
                    logger.info("Bulk-probe iter=\(i) clearHalt issued")
                }
                if heartbeat {
                    if let r = try? await usbManager.vendorIn(deviceIndex: 0, bRequest: 0x49, wValue: 0, wLength: 1) {
                        logger.info("Bulk-probe iter=\(i) heartbeat=\(r.map { String(format: "%02X", $0) }.joined())")
                    }
                }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: delay * 1_000_000)
                }
            }
        }

        if otherDevPoll || sameDevPoll {
            await usbManager.stopOtherDeviceHeartbeatPolling()
        }

        if let s = iosurfaceHolder {
            IOSurfaceUnlock(s, [], nil)
        }
    }

    /// Open a CGDisplayStream against the main display, wait for the first
    /// frame callback, retain its IOSurface and return. Mirrors UsbDisplay's
    /// frame source — a display-bound IOSurface managed by the GPU/window
    /// server stack. Tests Hypothesis H' (the deeper variant): not "any
    /// IOSurface" but specifically a *display-stream-bound* one is what
    /// flips the kernel into the unrestricted-DMA path.
    private nonisolated func captureDisplayStreamSurface(timeoutSeconds: Double) -> IOSurfaceRef? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = SurfaceBox()
        let queue = DispatchQueue(label: "RacerUSB.captureDisplay")
        let pixelFormatBGRA: Int32 = Int32(bitPattern: 0x42475241)  // 'BGRA'

        guard let stream = CGDisplayStream(
            dispatchQueueDisplay: CGMainDisplayID(),
            outputWidth: 1920,
            outputHeight: 1200,
            pixelFormat: pixelFormatBGRA,
            properties: nil,
            queue: queue,
            handler: { (status, displayTime, frameSurface, updateRef) in
                guard box.surface == nil else { return }
                guard status == .frameComplete else { return }
                if let s = frameSurface {
                    IOSurfaceIncrementUseCount(s)
                    box.surface = s
                    semaphore.signal()
                }
            }
        ) else { return nil }

        if stream.start() != .success {
            return nil
        }
        _ = semaphore.wait(timeout: .now() + timeoutSeconds)
        _ = stream.stop()
        return box.surface
    }
}

private final class SurfaceBox: @unchecked Sendable {
    var surface: IOSurfaceRef?
}

// MARK: - SCStream-based surface capture (CMCapture-mediated pipeline)

@available(macOS 12.3, *)
extension DriverOrchestrator {
    nonisolated func captureSCStreamSurface(timeoutSeconds: Double) async -> IOSurfaceRef? {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                return nil
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 1920
            config.height = 1200
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 5

            let collector = SCStreamSurfaceCollector()
            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: DispatchQueue(label: "RacerUSB.scstream"))
            try await stream.startCapture()

            let surface = collector.waitForSurface(timeout: timeoutSeconds)
            try? await stream.stopCapture()
            return surface
        } catch {
            return nil
        }
    }
}

@available(macOS 12.3, *)
extension DriverOrchestrator {
    nonisolated func runSCStreamDispatchProbe(collector: SCStreamDispatchProbeCollector, timeoutSeconds: Double) async -> Int32 {
        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first else {
                return Int32.min
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let config = SCStreamConfiguration()
            config.width = 1920
            config.height = 1200
            config.pixelFormat = kCVPixelFormatType_32BGRA
            config.queueDepth = 5

            let stream = SCStream(filter: filter, configuration: config, delegate: nil)
            try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: DispatchQueue(label: "RacerUSB.scdispatch"))
            try await stream.startCapture()

            let rc = collector.waitForResult(timeout: timeoutSeconds)
            try? await stream.stopCapture()
            return rc
        } catch {
            return Int32.min
        }
    }
}

@available(macOS 12.3, *)
final class SCStreamDispatchProbeCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private let device: OpaquePointer
    private let size: Int
    private var resultRc: Int32 = 0
    private var done: Bool = false
    private let semaphore = DispatchSemaphore(value: 0)

    init(device: OpaquePointer, size: Int) {
        self.device = device
        self.size = size
        super.init()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if done || type != .screen { return }
        guard let imageBuf = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let surfaceRef = CVPixelBufferGetIOSurface(imageBuf) else { return }
        let surface = surfaceRef.takeUnretainedValue()
        IOSurfaceLock(surface, [], nil)
        defer { IOSurfaceUnlock(surface, [], nil) }
        let base = IOSurfaceGetBaseAddress(surface)
        // Fill first `size` bytes with 0x55 — same content as our standard probe
        base.initializeMemory(as: UInt8.self, repeating: 0x55, count: size)

        var transferred: UInt32 = 0
        // Call iokit_usb_bulk_write directly here — running on the
        // libdispatch workloop owned by ScreenCaptureKit/CMCapture, which
        // is the same dispatch context UsbDisplay's 825K writes use.
        let rc = iokit_usb_bulk_write(
            device,
            /* pipe_ref */ 1,
            base.assumingMemoryBound(to: UInt8.self),
            UInt32(size),
            /* no_data_timeout_ms */ 500,
            /* completion_timeout_ms */ 500,
            /* max_retries */ 2,
            &transferred
        )
        resultRc = rc
        done = true
        semaphore.signal()
    }

    func waitForResult(timeout: Double) -> Int32 {
        let r = semaphore.wait(timeout: .now() + timeout)
        if r == .timedOut { return Int32.min }
        return resultRc
    }
}

@available(macOS 12.3, *)
private final class SCStreamSurfaceCollector: NSObject, SCStreamOutput, @unchecked Sendable {
    private var captured: IOSurfaceRef?
    private let semaphore = DispatchSemaphore(value: 0)

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard captured == nil, type == .screen else { return }
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        guard let surfaceRef = CVPixelBufferGetIOSurface(imageBuffer) else { return }
        let s = surfaceRef.takeUnretainedValue()
        IOSurfaceIncrementUseCount(s)
        captured = s
        semaphore.signal()
    }

    func waitForSurface(timeout: Double) -> IOSurfaceRef? {
        _ = semaphore.wait(timeout: .now() + timeout)
        return captured
    }
}
