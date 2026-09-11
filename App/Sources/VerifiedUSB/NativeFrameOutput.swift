import Foundation
import VerifiedDisplayCore

public struct NativeCaptureConfiguration: Codable, Sendable {
    public var displayID: UInt32
    public var usbPath: String
    public var deviceID: UInt32
    public var directory: URL
    public var ownerPID: Int32
    public var fps: Int
    public var seconds: Int
    public var send: Bool
    public var profile: Bool
    public var performance: PerformanceOptions
    public var stopFile: URL
    public init(displayID: UInt32,usbPath: String,deviceID: UInt32,directory: URL,ownerPID: Int32,
                fps: Int,seconds: Int,send: Bool,profile: Bool,performance: PerformanceOptions,stopFile: URL) {
        self.displayID=displayID;self.usbPath=usbPath;self.deviceID=deviceID;self.directory=directory;self.ownerPID=ownerPID
        self.fps=fps;self.seconds=seconds;self.send=send;self.profile=profile;self.performance=performance;self.stopFile=stopFile
    }
    public var arguments: [String] {
        ["--display",String(displayID),"--fps",String(fps),"--seconds",String(seconds)] + performance.arguments +
        (profile ? ["--profile"] : [])+["--stop-file",stopFile.path,"--hold-exit"]
    }
}

/// Lives on the capture preparation task; no cross-process frame copy or ACK.
public final class NativeFrameOutput {
    private let config: NativeCaptureConfiguration
    private let log: NativeEventLog
    private var usb: NativeUSB?
    private var validator=FrameValidation()
    private var frames=0,bytes=0,errors=0,idle=0
    private let started=ProcessInfo.processInfo.systemUptime
    private var lastPublish=0.0
    public init(_ config: NativeCaptureConfiguration) throws {
        self.config=config;log=try NativeEventLog(config.directory.appendingPathComponent("events.jsonl"))
        guard config.ownerPID==getppid(),config.performance.isValid else { throw NativeError.invalid("invalid capture owner or performance options") }
        if config.send {
            usb=try NativeUSB(path:config.usbPath,deviceID:config.deviceID) { [log] in try? log.write($0) }
        }
        try publish(force:true)
    }
    public func send(_ data: Data) throws -> Int {
        let start=ProcessInfo.processInfo.systemUptime
        do {
            let tiles=try validator.validate(data,keyframe:frames<2)
            let validated=ProcessInfo.processInfo.systemUptime
            let actual=try usb?.write(data) ?? data.count
            frames+=1;bytes+=config.send ? actual : 0
            let completed=ProcessInfo.processInfo.systemUptime
            if config.profile || frames<=2 {
                try log.write(["event":config.send ? "bulk" : "simulated_completion","index":frames-1,
                    "requested":data.count,"actual":actual,"status":"complete","tiles":tiles,
                    "validation_seconds":validated-start,"seconds":completed-validated])
            }
            if frames==1 { try data.write(to:config.directory.appendingPathComponent("first_frame.bin")) }
            if frames==2 { try NativeFiles.touch(config.directory.appendingPathComponent("stream_ready")) }
            try publish();return actual
        } catch {
            errors+=1
            var row: [String:Any]=["result":"failed","error":String(describing:error)]
            if let failure=error as? USBWriteFailure {
                row["usb_status"]=failure.status;row["actual"]=failure.actual;row["expected"]=failure.expected
            }
            if config.send,let paths=try? NativeUSB.paths() { row["usb_paths_at_failure"]=paths }
            try? NativeFiles.write(row,to:config.directory.appendingPathComponent("result.json"))
            try? log.write(["event":"failure","error":String(describing:error)])
            try? publish(force:true)
            throw error
        }
    }
    public func recordIdle() throws { idle+=1;try publish() }
    public func finish() throws {
        try publish(force:true)
        try NativeFiles.write(["result":config.send ? "usb_complete_visual_pending" : "offline_capture_complete",
                               "frames":frames,"bytes":bytes],to:config.directory.appendingPathComponent("result.json"))
    }
    private func publish(force: Bool = false) throws {
        let now=ProcessInfo.processInfo.systemUptime
        guard force || now-lastPublish>=1 else { return }
        lastPublish=now;let elapsed=now-started
        try NativeFiles.write(["frames":frames,"bytes":bytes,"transfer_errors":errors,"idle_records":idle,
            "elapsed_seconds":elapsed,"average_updates_per_second":Double(frames)/max(elapsed,0.001),
            "last_activity_unix":Date().timeIntervalSince1970,"mode":config.send ? "usb" : "simulated"],
            to:config.directory.appendingPathComponent("progress.json"))
    }
}
