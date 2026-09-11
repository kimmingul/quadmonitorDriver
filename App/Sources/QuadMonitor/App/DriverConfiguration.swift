import Foundation

struct DriverConfiguration: Sendable {
    enum Mode: String, Sendable {
        case dryRun
        case hardware
    }

    let mode: Mode
    let monitorCount: Int
    let targetFPS: Int
    let mockTransportLatencyMs: UInt64
    let vendorID: UInt16
    let productID: UInt16
    let probeOnly: Bool
    let probeLimit: Int
    let testFrame: Bool
    /// Single-shot bulk write probe size in bytes. When non-nil the orchestrator
    /// runs the unlock sequence on device 0, sends one bulk OUT of this size,
    /// logs the result, and exits. No retries, no second device — designed to
    /// measure the hard cap without wedging multiple units.
    let bulkProbeSize: Int?
    /// How many back-to-back bulk writes to issue (default 1). Each iteration
    /// is logged separately so the ring-fill behavior is observable.
    let bulkProbeCount: Int
    /// Sleep between consecutive probe writes, in milliseconds. 0 = no sleep.
    let bulkProbeDelayMs: UInt64
    /// If true, issue a vendor IN read of bReq=0x49 (heartbeat) between probe
    /// writes — a hypothesis for the bulk-OUT ring-drain trigger.
    let bulkProbeHeartbeatBetween: Bool
    /// If true, call libusb_clear_halt on the bulk endpoint between probe
    /// writes — alternate hypothesis for the ring-drain trigger.
    let bulkProbeClearHaltBetween: Bool
    /// Optional path to a binary file whose contents are tiled to fill the
    /// probe buffer (mod-N). When nil the buffer is filled with 0x55. Used to
    /// test the content hypothesis: does the firmware accept arbitrary bytes
    /// or does it inspect the bulk OUT stream and stall on garbage?
    let bulkProbePayloadPath: String?
    /// Path to a binary file replayed to device 0 as a sequence of bulk writes,
    /// each `replayChunk` bytes (last write = remainder), advancing through the
    /// file. Unlike `bulkProbePayloadPath` (one tiled write), this reproduces the
    /// vendor's many-small-writes pattern so the firmware decoder drains the ring
    /// between writes. Logs cumulative bytes accepted before any stall.
    let replayFilePath: String?
    /// Per-write chunk size for `replayFilePath`. Default 1409 = the vendor's
    /// observed first WritePipe size, and not a multiple of 512 so every write
    /// ends with a short packet (a candidate ring-drain signal).
    let replayChunk: Int
    /// Directory of `frame_*.bin` files, each a complete captured vendor frame
    /// (one WritePipeTO ending in a short packet). Replayed in sorted order, one
    /// bulk write per frame, to test whether streaming complete frames sustains
    /// the firmware ring drain past the 16384 cold-start ceiling.
    let replayFramesDir: String?
    /// Skip frames larger than this many bytes during `replayFramesDir` (0 =
    /// no limit). Lets us prime with small frames first, avoiding the big-frame
    /// cold-start stall.
    let replayMaxBytes: Int
    /// Repeat the whole `replayFramesDir` sequence this many times (default 1).
    let replayLoops: Int
    /// Use the legacy IOKit / IOUSBLib USB transport. Has the same 8KB cap as
    /// libusb on macOS 26 — kept as a comparison path during P3 investigation.
    let useIOKit: Bool
    /// Use Apple's IOUSBHost framework — the modern dispatch-queue-based USB
    /// API the original UsbDisplay.app uses on macOS 26 (verified via lldb
    /// trace). This is the only known path that bypasses the 8KB-per-session
    /// cap on Apple Silicon.
    let useIOUSBHost: Bool
    /// Step C1: path to a single pre-encoded 0xD0 frame streamed CONTINUOUSLY to
    /// device 0 at `targetFPS`, recovering (clearHalt) on stall instead of
    /// aborting. Tests whether a sustained frame stream makes the device leave
    /// its buffer and actively scan out (present) to the panel — the last
    /// unknown after the encoder was proven byte-exact + transport-conformant.
    let streamFramePath: String?
    /// Duration in seconds for `streamFramePath` (default 20). 0 = run forever.
    let streamSeconds: Int
    /// Stream the `streamFramePath` frame to ALL opened devices concurrently
    /// (libusb async) instead of only device 0 — the hypothesis Q' test.
    let streamAllDevices: Bool

    static let `default` = DriverConfiguration(
        mode: .dryRun,
        monitorCount: 3,
        targetFPS: 60,
        mockTransportLatencyMs: 2,
        vendorID: 0x34C7,
        productID: 0x2114,
        probeOnly: false,
        probeLimit: 64,
        testFrame: false,
        bulkProbeSize: nil,
        bulkProbeCount: 1,
        bulkProbeDelayMs: 0,
        bulkProbeHeartbeatBetween: false,
        bulkProbeClearHaltBetween: false,
        bulkProbePayloadPath: nil,
        replayFilePath: nil,
        replayChunk: 1409,
        replayFramesDir: nil,
        replayMaxBytes: 0,
        replayLoops: 1,
        useIOKit: false,
        useIOUSBHost: false,
        streamFramePath: nil,
        streamSeconds: 20,
        streamAllDevices: false
    )

    /// Extract `value` from `--flag=value`. Returns nil when the prefix does
    /// not match exactly (so `--bulk-probe-count=4` cannot accidentally match
    /// `--bulk-probe=`). Empty value -> nil. Uses dropFirst rather than split
    /// so values containing `=` (e.g. paths) survive intact.
    private static func flagValue(_ arg: String, _ flag: String) -> String? {
        let key = flag + "="
        guard arg.hasPrefix(key) else { return nil }
        let v = String(arg.dropFirst(key.count))
        return v.isEmpty ? nil : v
    }

    static func fromProcessArguments(_ args: [String]) -> DriverConfiguration {
        var mode = Mode.dryRun
        var monitorCount = 3
        var targetFPS = 60
        var vendorID: UInt16 = 0x34C7
        var productID: UInt16 = 0x2114
        var probeOnly = false
        var probeLimit = 64
        var testFrame = false
        var bulkProbeSize: Int? = nil
        var bulkProbeCount = 1
        var bulkProbeDelayMs: UInt64 = 0
        var bulkProbeHeartbeatBetween = false
        var bulkProbeClearHaltBetween = false
        var bulkProbePayloadPath: String? = nil
        var replayFilePath: String? = nil
        var replayChunk = 1409
        var replayFramesDir: String? = nil
        var replayMaxBytes = 0
        var replayLoops = 1
        var useIOKit = false
        var useIOUSBHost = false
        var streamFramePath: String? = nil
        var streamSeconds = 20
        var streamAllDevices = false

        // argv[0] is the executable path — skip it so a path containing
        // "--something" doesn't trigger the unknown-flag warning.
        for arg in args.dropFirst() {
            switch arg {
            case "--hardware":            mode = .hardware;             continue
            case "--probe":               probeOnly = true;             continue
            case "--test-frame":          testFrame = true;             continue
            case "--bulk-heartbeat-between": bulkProbeHeartbeatBetween = true; continue
            case "--bulk-clear-halt-between": bulkProbeClearHaltBetween = true; continue
            case "--use-iokit":           useIOKit = true;              continue
            case "--use-iousbhost":       useIOUSBHost = true;          continue
            case "--stream-all-devices":  streamAllDevices = true;      continue
            default: break
            }

            if let v = flagValue(arg, "--monitors"), let n = Int(v) {
                monitorCount = max(1, min(4, n))
            } else if let v = flagValue(arg, "--fps"), let n = Int(v) {
                targetFPS = max(30, min(120, n))
            } else if let v = flagValue(arg, "--vid"),
                      let n = UInt16(v.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                vendorID = n
            } else if let v = flagValue(arg, "--pid"),
                      let n = UInt16(v.replacingOccurrences(of: "0x", with: ""), radix: 16) {
                productID = n
            } else if let v = flagValue(arg, "--probe-limit"), let n = Int(v) {
                probeLimit = max(1, min(256, n))
            } else if let v = flagValue(arg, "--bulk-probe"), let n = Int(v) {
                bulkProbeSize = max(1, min(1 << 24, n))
            } else if let v = flagValue(arg, "--bulk-probe-count") ?? flagValue(arg, "--bulk-count"),
                      let n = Int(v) {
                // Canonical name: --bulk-probe-count. --bulk-count kept as
                // legacy alias for command-line diagnostic callers.
                bulkProbeCount = max(1, min(1024, n))
            } else if let v = flagValue(arg, "--bulk-delay-ms"), let n = UInt64(v) {
                bulkProbeDelayMs = min(60_000, n)
            } else if let v = flagValue(arg, "--bulk-probe-payload") {
                bulkProbePayloadPath = v
            } else if let v = flagValue(arg, "--replay-file") {
                replayFilePath = v
            } else if let v = flagValue(arg, "--replay-chunk"), let n = Int(v) {
                replayChunk = max(1, min(1 << 20, n))
            } else if let v = flagValue(arg, "--replay-frames-dir") {
                replayFramesDir = v
            } else if let v = flagValue(arg, "--replay-max-bytes"), let n = Int(v) {
                replayMaxBytes = max(0, n)
            } else if let v = flagValue(arg, "--replay-loops"), let n = Int(v) {
                replayLoops = max(1, min(100_000, n))
            } else if let v = flagValue(arg, "--stream-frame") {
                streamFramePath = v
            } else if let v = flagValue(arg, "--stream-seconds"), let n = Int(v) {
                streamSeconds = max(0, min(3600, n))
            } else if arg.hasPrefix("--") {
                FileHandle.standardError.write(Data("warning: unknown flag '\(arg)' ignored\n".utf8))
            }
        }

        return DriverConfiguration(
            mode: mode,
            monitorCount: monitorCount,
            targetFPS: targetFPS,
            mockTransportLatencyMs: 2,
            vendorID: vendorID,
            productID: productID,
            probeOnly: probeOnly,
            probeLimit: probeLimit,
            testFrame: testFrame,
            bulkProbeSize: bulkProbeSize,
            bulkProbeCount: bulkProbeCount,
            bulkProbeDelayMs: bulkProbeDelayMs,
            bulkProbeHeartbeatBetween: bulkProbeHeartbeatBetween,
            bulkProbeClearHaltBetween: bulkProbeClearHaltBetween,
            bulkProbePayloadPath: bulkProbePayloadPath,
            replayFilePath: replayFilePath,
            replayChunk: replayChunk,
            replayFramesDir: replayFramesDir,
            replayMaxBytes: replayMaxBytes,
            replayLoops: replayLoops,
            useIOKit: useIOKit,
            useIOUSBHost: useIOUSBHost,
            streamFramePath: streamFramePath,
            streamSeconds: streamSeconds,
            streamAllDevices: streamAllDevices
        )
    }
}
