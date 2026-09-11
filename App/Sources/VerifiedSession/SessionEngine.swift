import Foundation
import VerifiedUSB

func displayList(_ host: URL) throws -> [[String:Any]] {
    let result=try command(host.path,["--list"])
    guard result.status==0,let data=result.output.data(using:.utf8),
          let row=try JSONSerialization.jsonObject(with:data) as? [String:Any],let displays=row["displays"] as? [[String:Any]]
    else { throw NativeError.invalid("cannot enumerate displays") }
    return displays
}

func devicePresence(_ options: SessionOptions, _ mapping: [PanelMapping]) throws -> [String:Any] {
    let paths=try NativeUSB.paths(),missing=PanelMapping.missing(mapping,paths:paths)
    let displays=missing.isEmpty ? try displayList(options.host) : []
    let originals=displays.filter { $0["vendor_id"] as? Int == 0x34c7 }.count
    let owned=displays.contains { $0["vendor_id"] as? Int == 0x5155 }
    let vendorReady=try originals>=mapping.count || !VendorOwnership.loaded()
    return ["paths":paths,"missing_paths":missing,"connected":missing.isEmpty,
            "ready":missing.isEmpty && !owned && vendorReady]
}

final class SessionEngine {
    private var options: SessionOptions
    private let mapping: [PanelMapping]
    private let signal: StopSignal
    private var directory: URL!
    private var log: NativeEventLog!
    private var host: Process?
    private var hostInput: Pipe?
    private var hostOutput: Pipe?
    private var workers=[String:Process]()
    private var inputs=[String:Pipe]()
    private var files=[FileHandle]()
    private var manifest=[String:Any]()
    private var disconnected=false
    init(_ options: SessionOptions,_ mapping: [PanelMapping],signal: StopSignal) {
        self.options=options;self.mapping=mapping;self.signal=signal
    }
    private var stopFile: URL { directory.appendingPathComponent("stop_captures") }
    private var requestFile: URL { directory.appendingPathComponent("stop.request") }
    private var stopped: Bool {
        signal.requested || (options.ownerPID.map{$0 != getppid()} ?? false) || FileManager.default.fileExists(atPath:requestFile.path)
    }
    private func event(_ row: [String:Any]) { try? log.write(row) }
    private func panelStats() -> [String:Any] {
        var result=[String:Any]()
        for row in mapping {
            if let stats=NativeFiles.read(directory.appendingPathComponent(row.role+"/progress.json")) { result[row.role]=stats }
        }
        return result
    }
    private func status(_ state: String, error: String? = nil) throws {
        var row:[String:Any]=["pid":getpid(),"directory":directory.path,"stop_file":requestFile.path,
             "state":state,"updated_at":ISO8601DateFormatter().string(from:Date()),"fps":options.fps,"panels":panelStats()]
        if let error { row["error"]=error }
        if disconnected { row["termination_reason"]="usb_disconnected" }
        try NativeFiles.write(row,to:options.control.appendingPathComponent("status.json"))
    }
    private func openLog(_ name: String) throws -> FileHandle {
        let path=directory.appendingPathComponent(name)
        FileManager.default.createFile(atPath:path.path,contents:nil)
        let file=try FileHandle(forWritingTo:path);files.append(file);return file
    }
    func run() throws -> Int32 {
        let ownership=try SessionLock(options.control)
        return try withExtendedLifetime(ownership) {
            directory=options.runs.appendingPathComponent("native_"+ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")+"_"+UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            log=try NativeEventLog(directory.appendingPathComponent("events.jsonl"))
            manifest=["engine":"native","started_at":ISO8601DateFormatter().string(from:Date()),"arguments":CommandLine.arguments,
                      "fps_requested":options.fps,"send":options.send,"visual_confirmation":"pending","result":"in_progress"]
            try Data(contentsOf:options.mapping).write(to:directory.appendingPathComponent("panel-layout.json"))
            try status("starting")
            let vendor=VendorOwnership();var failure: String?
            do {
                try preflight()
                if stopped { throw SessionCancelled() }
                try vendor.acquire(takeover:options.takeover)
                event(["event":"vendor_acquired"])
                try startAndMonitor()
            } catch is SessionCancelled { event(["event":"startup_cancelled"]) }
            catch { failure=String(describing:error);event(["event":"failure","error":failure!]) }
            // Capture-time enumeration can catch a fast unplug/replug missed by polling.
            for row in mapping {
                if let result=NativeFiles.read(directory.appendingPathComponent(row.role+"/result.json")),
                   let paths=result["usb_paths_at_failure"] as? [String],!PanelMapping.missing(mapping,paths:paths).isEmpty {
                    disconnected=true;manifest["worker_disconnect_observation"]=result
                }
            }
            do { try cleanup() } catch { failure=(failure.map{$0+"; "} ?? "")+String(describing:error) }
            do { try vendor.restore();event(["event":"vendor_restored"]) }
            catch { failure=(failure.map{$0+"; "} ?? "")+String(describing:error) }
            manifest["finished_at"]=ISO8601DateFormatter().string(from:Date())
            manifest["result"]=failure == nil ? (options.send ? "usb_complete_visual_pending" : "offline_capture_complete") : "failed"
            manifest["panels"]=panelStats();manifest["error"]=failure
            if disconnected { manifest["termination_reason"]="usb_disconnected" }
            try NativeFiles.write(manifest,to:directory.appendingPathComponent("manifest.json"))
            try status(failure == nil ? "stopped" : "failed",error:failure)
            return failure == nil ? 0 : 1
        }
    }
    private func preflight() throws {
        guard try command(options.host.path,["--preflight"]).status==0,
              try command(options.capture.path,["--preflight"]).output.contains("screen_capture_authorized=true")
        else { throw NativeError.invalid("virtual display or screen capture permission unavailable") }
        if options.send {
            let paths=try NativeUSB.paths()
            if !PanelMapping.missing(mapping,paths:paths).isEmpty {
                disconnected=true;throw NativeError.invalid("confirmed USB panel disconnected")
            }
        }
        guard !(try displayList(options.host)).contains(where:{$0["vendor_id"] as? Int == 0x5155})
        else { throw NativeError.invalid("an owned virtual desktop session is already present") }
    }
    private func startAndMonitor() throws {
        if options.performance.workers==0 {
            let result=try? command("/usr/sbin/sysctl",["-n","hw.perflevel0.physicalcpu"])
            let cores=result.flatMap{Int($0.output.trimmingCharacters(in:.whitespacesAndNewlines))} ?? ProcessInfo.processInfo.activeProcessorCount
            let budget=max(1,cores/mapping.count);options.performance.workers=[1,2,4,8].last(where:{$0<=budget})!
        }
        let process=Process(),input=Pipe(),output=Pipe()
        process.executableURL=options.host
        process.arguments=["--run","--seconds",String(options.seconds==0 ? 0 : options.seconds+45),"--panels",options.roles.joined(separator:",")]+(options.demo ? ["--demo","--demo-fps",String(options.fps)] : [])
        process.standardInput=input;process.standardOutput=output;process.standardError=try openLog("host.stderr")
        try process.run();host=process;hostInput=input;hostOutput=output
        let ready=try readReady(output,child:process,deadline:ProcessInfo.processInfo.systemUptime+15,stopped:{self.stopped})
        guard let displays=ready["displays"] as? [[String:Any]] else { throw NativeError.invalid("missing virtual displays") }
        let bound=try PanelMapping.bind(mapping,displays:displays);manifest["virtual_displays"]=displays;event(ready)
        for row in mapping {
            if stopped { throw SessionCancelled() }
            let panel=directory.appendingPathComponent(row.role)
            try FileManager.default.createDirectory(at:panel,withIntermediateDirectories:false)
            let config=NativeCaptureConfiguration(displayID:bound[row.role]!,usbPath:row.usbPath,deviceID:row.deviceID,
                directory:panel,ownerPID:getpid(),fps:options.fps,seconds:options.seconds,send:options.send,
                profile:FileManager.default.fileExists(atPath:options.control.appendingPathComponent("profile.capture").path),
                performance:options.performance,stopFile:stopFile)
            let configPath=panel.appendingPathComponent("config.json")
            try JSONEncoder().encode(config).write(to:configPath,options:.atomic)
            let child=Process(),pipe=Pipe();child.executableURL=options.capture
            child.arguments=["--native-config",configPath.path];child.standardInput=pipe
            child.standardOutput=FileHandle.nullDevice;child.standardError=try openLog(row.role+"/capture.stderr")
            try child.run();workers[row.role]=child;inputs[row.role]=pipe
            event(["event":"worker_started","role":row.role,"pid":child.processIdentifier])
            let deadline=ProcessInfo.processInfo.systemUptime+15
            while !FileManager.default.fileExists(atPath:panel.appendingPathComponent("stream_ready").path) {
                try health()
                if stopped { throw SessionCancelled() }
                guard ProcessInfo.processInfo.systemUptime<deadline else { throw NativeError.invalid("first frame deadline exceeded") }
                Thread.sleep(forTimeInterval:0.05)
            }
            event(["event":"first_two_frames_acknowledged","role":row.role])
        }
        try status("running");event(["event":"session_running"])
        var nextCheck=0.0,stopDeadline: Double?,released=false
        let deadline=options.seconds==0 ? Double.infinity : ProcessInfo.processInfo.systemUptime+Double(options.seconds)+25
        while true {
            try health()
            let now=ProcessInfo.processInfo.systemUptime
            if stopped && stopDeadline==nil { try NativeFiles.touch(stopFile);stopDeadline=now+25;try status("stopping") }
            guard now<deadline,now<(stopDeadline ?? .infinity) else { throw NativeError.invalid("capture completion deadline exceeded") }
            if now>=nextCheck { nextCheck=now+1;try status(stopDeadline==nil ? "running" : "stopping") }
            if !released,mapping.allSatisfy({FileManager.default.fileExists(atPath:directory.appendingPathComponent($0.role+"/capture_completed").path)}) {
                for pipe in inputs.values { try pipe.fileHandleForWriting.write(contentsOf:Data([81])) }
                released=true;event(["event":"all_captures_stopped_release_processes"])
            }
            if workers.values.allSatisfy({!$0.isRunning}) { break }
            Thread.sleep(forTimeInterval:0.05)
        }
    }
    private var nextUSBCheck=0.0
    private func health() throws {
        guard host?.isRunning==true else { throw NativeError.invalid("virtual display host exited during capture") }
        let now=ProcessInfo.processInfo.systemUptime
        if options.send,now>=nextUSBCheck {
            nextUSBCheck=now+2
            let paths=try NativeUSB.paths()
            if !PanelMapping.missing(mapping,paths:paths).isEmpty { disconnected=true;throw NativeError.invalid("USB disconnected") }
        }
        for (role,child) in workers where !child.isRunning {
            child.waitUntilExit()
            if child.terminationStatus != 0 { throw NativeError.invalid("\(role) capture exited: \(child.terminationStatus)") }
        }
    }
    private func cleanup() throws {
        try? NativeFiles.touch(stopFile)
        let deadline=ProcessInfo.processInfo.systemUptime+5
        while ProcessInfo.processInfo.systemUptime<deadline,
              workers.contains(where:{role,child in child.isRunning && !FileManager.default.fileExists(atPath:directory.appendingPathComponent(role+"/capture_completed").path)}) {
            Thread.sleep(forTimeInterval:0.05)
        }
        for pipe in inputs.values { try? pipe.fileHandleForWriting.write(contentsOf:Data([81]));try? pipe.fileHandleForWriting.close() }
        for child in workers.values {
            let grace=ProcessInfo.processInfo.systemUptime+1
            while child.isRunning && ProcessInfo.processInfo.systemUptime<grace { Thread.sleep(forTimeInterval:0.02) }
            if child.isRunning { stopChild(child) } else { child.waitUntilExit() }
        }
        try? hostInput?.fileHandleForWriting.close()
        if let host {
            let deadline=ProcessInfo.processInfo.systemUptime+5
            while host.isRunning && ProcessInfo.processInfo.systemUptime<deadline { Thread.sleep(forTimeInterval:0.05) }
            if host.isRunning { stopChild(host) } else { host.waitUntilExit() }
        }
        // The host writes its final record after stdin closes. Keep its reader alive
        // through process exit so graceful shutdown cannot become SIGPIPE.
        if let output=hostOutput {
            try? output.fileHandleForWriting.close()
            let trailing=try output.fileHandleForReading.readToEnd() ?? Data()
            if !trailing.isEmpty { event(["event":"host_shutdown_output","output":String(decoding:trailing,as:UTF8.self)]) }
            try? output.fileHandleForReading.close();hostOutput=nil
        }
        for file in files { try? file.close() };files.removeAll()
        // With no host created we must not mistake another session for our leak.
        if let host {
            let deadline=ProcessInfo.processInfo.systemUptime+5
            while try displayList(options.host).contains(where:{$0["vendor_id"] as? Int == 0x5155}) {
                guard ProcessInfo.processInfo.systemUptime<deadline else { throw NativeError.invalid("virtual displays remain after host exit") }
                Thread.sleep(forTimeInterval:0.1)
            }
            guard host.terminationStatus==0 else { throw NativeError.invalid("virtual display host abnormal exit: \(host.terminationStatus)") }
        }
    }
}
