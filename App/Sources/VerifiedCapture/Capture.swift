import Foundation
import ScreenCaptureKit
import CoreGraphics
import CoreMedia
import CoreVideo
import VerifiedDisplayCore
import VerifiedUSB

private enum CaptureError: Error { case arguments, permission, displayMissing, noFrames, rejected, unsupportedOS, stream(String) }

private func log(_ values: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) {
        FileHandle.standardError.write(data + Data([10]))
    }
}

// All mutable fields are protected by lock. Capture never waits for encoding/USB.
private final class LatestCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let arrival = FrameArrival()
    private let lock = NSLock()
    private var latest: EncodingSnapshot?
    private var error: String?
    private var count = 0
    private var copySeconds = 0.0

    func snapshot() throws -> EncodingSnapshot? {
        lock.lock(); defer { lock.unlock() }
        if let error { throw CaptureError.stream(error) }
        return latest
    }
    func metrics() -> (count: Int, copySeconds: Double) {
        lock.lock(); defer { lock.unlock() }
        return (count, copySeconds)
    }
    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        lock.lock(); self.error = String(describing: error); let next=count+1; lock.unlock(); arrival.publish(next)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sample.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int,
              status == SCFrameStatus.complete.rawValue,
              let image = CMSampleBufferGetImageBuffer(sample),
              CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_32BGRA,
              CVPixelBufferGetWidth(image) == 1920, CVPixelBufferGetHeight(image) == 1200,
              CVPixelBufferLockBaseAddress(image, .readOnly) == kCVReturnSuccess else { return }
        defer { CVPixelBufferUnlockBaseAddress(image, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(image) else { return }
        let stride = CVPixelBufferGetBytesPerRow(image)
        let beforeCopy = ProcessInfo.processInfo.systemUptime
        let data = Data(bytes: base, count: stride * 1200)
        let now = ProcessInfo.processInfo.systemUptime
        lock.lock()
        count += 1; copySeconds += now-beforeCopy
        latest = EncodingSnapshot(pixels: data, stride: stride, generation: count, createdAt: now)
        let generation=count
        lock.unlock(); arrival.publish(generation)
    }
}

@main struct VerifiedCapture {
    static func main() async {
        do { try await run() }
        catch { log(["event": "failure", "error": String(describing: error)]); exit(1) }
    }

    static func run() async throws {
        signal(SIGPIPE,SIG_IGN)
        var args = Array(CommandLine.arguments.dropFirst())
        var native: NativeCaptureConfiguration?
        if args.count==2,args[0]=="--native-config" {
            native=try JSONDecoder().decode(NativeCaptureConfiguration.self,from:Data(contentsOf:URL(fileURLWithPath:args[1])))
            args=native!.arguments
        }
        let nativeConfiguration=native
        let holdExit = args.last == "--hold-exit"
        if holdExit { args.removeLast() }
        var stopFile: String?
        if args.count >= 2 && args[args.count-2] == "--stop-file" {
            stopFile=args.removeLast();args.removeLast()
        }
        let profile = args.last == "--profile"
        if profile { args.removeLast() }
        if args == ["--preflight"] {
            print("screen_capture_authorized=\(CGPreflightScreenCaptureAccess())")
            return
        }
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permission }
        log(["event": "content_requested"])
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        log(["event": "content_received", "display_ids": content.displays.map(\.displayID)])
        if args == ["--list"] {
            for display in content.displays { print("\(display.displayID) \(display.width)x\(display.height)") }
            return
        }
        var performance=PerformanceOptions()
        var options: [String: Int] = [:]
        guard args.count >= 6, args.count%2==0 else { throw CaptureError.arguments }
        var seen=Set<String>()
        for i in stride(from: 0, to: args.count, by: 2) {
            guard seen.insert(args[i]).inserted else { throw CaptureError.arguments }
            switch args[i] {
            case "--reuse-buffers", "--adaptive-workers", "--overlap-preparation":
                guard ["0","1"].contains(args[i+1]) else { throw CaptureError.arguments }
                let enabled = args[i+1] == "1"
                if args[i] == "--reuse-buffers" { performance.reuseBuffers=enabled }
                if args[i] == "--adaptive-workers" { performance.adaptiveWorkers=enabled }
                if args[i] == "--overlap-preparation" { performance.overlapPreparation=enabled }
                continue
            case "--encoder-workers": guard let n=Int(args[i+1]),[1,2,4,8].contains(n) else { throw CaptureError.arguments };performance.workers=n;continue
            case "--scheduling": guard let v=PerformanceOptions.Scheduling(rawValue:args[i+1]) else { throw CaptureError.arguments };performance.scheduling=v;continue
            case "--damage": guard let v=PerformanceOptions.Damage(rawValue:args[i+1]) else { throw CaptureError.arguments };performance.damage=v;continue
            case "--compression": guard let v=PerformanceOptions.Compression(rawValue:args[i+1]) else { throw CaptureError.arguments };performance.compression=v;continue
            case "--queue-depth": guard let n=Int(args[i+1]),[2,3,5].contains(n) else { throw CaptureError.arguments };performance.queueDepth=n;continue
            default:break
            }
            guard ["--display", "--fps", "--seconds"].contains(args[i]), options[args[i]] == nil,
                  let value = Int(args[i+1]) else { throw CaptureError.arguments }
            options[args[i]] = value
        }
        guard let id = options["--display"], id > 0, id <= Int(UInt32.max),
              let fps = options["--fps"], (1...60).contains(fps),
              let seconds = options["--seconds"], (0...3600).contains(seconds),
              seconds > 0 || stopFile != nil else { throw CaptureError.arguments }
        let sessionStopFile = stopFile
        guard let display = content.displays.first(where: { $0.displayID == UInt32(id) }) else { throw CaptureError.displayMissing }
        let config = SCStreamConfiguration()
        config.width = 1920; config.height = 1200
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: Int32(fps))
        config.queueDepth = performance.queueDepth; config.showsCursor = true
        config.scalesToFit = true
        if #available(macOS 14, *) { config.preservesAspectRatio = true }
        else { throw CaptureError.unsupportedOS }
        let performanceOptions=performance
        log(["event":"performance_options","workers":performance.workers,"scheduling":performance.scheduling.rawValue,
             "damage":performance.damage.rawValue,"compression":performance.compression.rawValue,"queue_depth":performance.queueDepth,
             "reuse_buffers":performance.reuseBuffers,"adaptive_workers":performance.adaptiveWorkers,
             "overlap_preparation":performance.overlapPreparation])
        let collector = LatestCapture()
        let stream = SCStream(filter: SCContentFilter(display: display, excludingWindows: []),
                              configuration: config, delegate: collector)
        try stream.addStreamOutput(collector, type: .screen, sampleHandlerQueue: DispatchQueue(label: "verified.capture"))
        log(["event": "stream_start_requested", "display_id": id])
        try await stream.startCapture()
        log(["event": "stream_started", "display_id": id])
        do {
            try await Task.detached {
                let output=try nativeConfiguration.map { try NativeFrameOutput($0) }
                var encoder = try DeltaEncoder(width: 1920, height: 1200, options:performanceOptions)
                let pipeline = performanceOptions.overlapPreparation ? FramePreparationPipeline() : nil
                defer { pipeline?.discard() }
                let started = ProcessInfo.processInfo.systemUptime
                var pacer = FramePacer(fps: fps, startedAt: started)
                let waiter = FrameWaiter()
                var lastOutput = started
                var sent = 0
                var lastGeneration = 0
                var windowStarted = started
                var incoming = collector.metrics()
                var totals: [String: Double] = [:]
                func add(_ name: String, _ value: Double) {
                    if profile { totals[name, default: 0] += value }
                }
                func report(_ force: Bool = false) {
                    guard profile else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    guard force || now-windowStarted >= 5 else { return }
                    let current = collector.metrics()
                    log(["event": "pipeline_metrics", "unix": Date().timeIntervalSince1970, "elapsed": now-started,
                         "window_seconds": now-windowStarted,
                         "incoming_frames": current.count-incoming.count,
                         "capture_copy_seconds": current.copySeconds-incoming.copySeconds,
                         "values": totals])
                    incoming=current; windowStarted=now; totals.removeAll(keepingCapacity: true)
                }
                while seconds == 0 || ProcessInfo.processInfo.systemUptime - started < Double(seconds) {
                    if let nativeConfiguration,nativeConfiguration.ownerPID != getppid() { break }
                    if let sessionStopFile, FileManager.default.fileExists(atPath: sessionStopFile) { break }
                    let tick = ProcessInfo.processInfo.systemUptime
                    var prepared: PreparedFrame?
                    var snapshotTime=tick, frameGeneration=0
                    if let snapshot = try collector.snapshot() {
                        add("prepare_attempts", 1)
                        add("repeated_generation", snapshot.generation == lastGeneration ? 1 : 0)
                        add("capture_age_seconds", tick-snapshot.createdAt)
                        lastGeneration=snapshot.generation
                        snapshotTime=snapshot.createdAt;frameGeneration=snapshot.generation
                        if let cached = pipeline?.take(generation:snapshot.generation) {
                            encoder=cached.encoder; prepared=cached.frame
                            add("overlap_hits",1)
                        } else {
                            prepared = try encoder.prepare(bgra: snapshot.pixels, stride: snapshot.stride, generation: snapshot.generation)
                            if pipeline != nil { add("overlap_misses",1) }
                        }
                        let metric=encoder.lastPreparation
                        add("canonical_copy_seconds", metric.copySeconds)
                        add("canonical_copied_bytes", Double(metric.copiedBytes))
                        add("compare_seconds", metric.compareSeconds)
                        add("encode_seconds", metric.encodeSeconds)
                        add("output_buffer_reuses",metric.outputBufferReused ? 1 : 0)
                        add("encoder_workers_sum",Double(metric.encoderWorkers))
                        add("settled_generation_skips", metric.reusedSettledGeneration ? 1 : 0)
                        if prepared == nil { add("unchanged_prepares", 1) }
                    }
                    if let frame = prepared {
                        // Parent validates and transmits, then ACKs exact completion.
                        // EOF/NACK aborts; stdout holds at most one immutable frame.
                        var length = UInt32(frame.data.count).littleEndian
                        var header = Data("RFR1".utf8)
                        withUnsafeBytes(of: &length) { header.append(contentsOf: $0) }
                        let writeStarted = ProcessInfo.processInfo.systemUptime
                        if output == nil {
                            try FileHandle.standardOutput.write(contentsOf: header)
                            try FileHandle.standardOutput.write(contentsOf: frame.data)
                        }
                        let waitStarted = ProcessInfo.processInfo.systemUptime
                        add("pipe_write_seconds", waitStarted-writeStarted)
                        if let pipeline, performanceOptions.shouldOverlap(changedTiles:frame.tiles.count) {
                            let generation=frameGeneration
                            let launched = try pipeline.start(encoder:encoder,completing:frame) {
                                // Wait only on the background worker. The ACK path
                                // never joins it; take() discards unfinished work.
                                collector.arrival.wait(after:generation,timeout:1.0/Double(fps))
                                return try collector.snapshot()
                            }
                            add("overlap_launched",launched ? 1 : 0)
                        }
                        let accepted: Bool
                        do {
                            if let output { accepted = try output.send(frame.data)==frame.data.count }
                            else { accepted = try FileHandle.standardInput.read(upToCount:1)==Data([65]) }
                        } catch {
                            pipeline?.acknowledge(frame,transferred:0,succeeded:false)
                            try? encoder.complete(frame,transferred:0,succeeded:false)
                            throw error
                        }
                        add("ack_wait_seconds", ProcessInfo.processInfo.systemUptime-waitStarted)
                        pipeline?.acknowledge(frame,transferred:accepted ? frame.data.count : 0,succeeded:accepted)
                        try encoder.complete(frame, transferred: accepted ? frame.data.count : 0, succeeded: accepted)
                        guard accepted else { throw CaptureError.rejected }
                        sent += 1
                        add("frames", 1)
                        lastOutput=ProcessInfo.processInfo.systemUptime
                        if profile { log(["event":"frame_timing","unix":Date().timeIntervalSince1970,
                                          "index":sent-1,"generation":frameGeneration,
                                          "snapshot_age_at_prepare_seconds":tick-snapshotTime,
                                          "snapshot_age_at_ack_seconds":lastOutput-snapshotTime]) }
                        if seconds > 0 || sent <= 2 {
                            log(["event": "acknowledged", "index": sent, "tiles": frame.tiles.count,
                                 "bytes": frame.data.count, "cycle_seconds": lastOutput-tick])
                        }
                    } else if sent >= 2 && tick-lastOutput >= 1 {
                        // An unchanged desktop is healthy. This record is never
                        // transmitted to USB or ACKed and does not advance history.
                        if let output { try output.recordIdle() }
                        else { try FileHandle.standardOutput.write(contentsOf: Data([82,70,73,49,0,0,0,0])) }
                        lastOutput=tick
                    }
                    let completedAt = ProcessInfo.processInfo.systemUptime
                    let deadline = performanceOptions.scheduling == .arrival
                        ? tick + 1.0/Double(fps) : pacer.deadline(completedAt: completedAt)
                    let remaining = deadline - completedAt
                    if remaining > 0 {
                        let beforeSleep=ProcessInfo.processInfo.systemUptime
                        if prepared != nil {
                            waiter.wait(untilUptime: deadline)
                        } else {
                            // An unchanged panel does not need strict timer wakeups.
                            try await Task.sleep(for: .seconds(remaining))
                        }
                        add("sleep_requested_seconds", remaining)
                        add("sleep_actual_seconds", ProcessInfo.processInfo.systemUptime-beforeSleep)
                    }
                    if performanceOptions.scheduling == .arrival {
                        // Wait for a genuinely new snapshot; bounded timeout still
                        // allows both history buffers to settle after motion stops.
                        collector.arrival.wait(after:lastGeneration,timeout:prepared == nil ? 0.1 : 1.0/Double(fps))
                    }
                    add("cycles", 1); report()
                }
                report(true)
                guard sent > 0 else { throw CaptureError.noFrames }
                try output?.finish()
                log(["event": "finished", "acknowledged": sent])
            }.value
        } catch {
            try? await stream.stopCapture()
            throw error
        }
        try await stream.stopCapture()
        if let nativeConfiguration {
            try NativeFiles.touch(nativeConfiguration.directory.appendingPathComponent("capture_completed"))
        }
        if holdExit {
            // Keep this process's ScreenCaptureKit connection alive until every
            // sibling has stopped. Early process exit interrupted a sibling on
            // the tested macOS runtime. EOF on stdout reports capture completion.
            log(["event": "waiting_for_session_release"])
            try FileHandle.standardOutput.close()
            let release = try FileHandle.standardInput.read(upToCount: 1)
            guard release == Data([81]) else { throw CaptureError.rejected }
            log(["event": "session_released"])
        }
    }
}
