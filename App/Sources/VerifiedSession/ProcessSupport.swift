import Foundation
import Darwin
import VerifiedUSB

struct CommandResult { let status: Int32;let output: String }
struct SessionCancelled: Error {}

func stopChild(_ child: Process, timeout: Double = 3) {
    if child.isRunning { child.terminate() }
    let deadline=ProcessInfo.processInfo.systemUptime+timeout
    while child.isRunning && ProcessInfo.processInfo.systemUptime<deadline { Thread.sleep(forTimeInterval:0.02) }
    if child.isRunning { _=kill(child.processIdentifier,SIGKILL) }
    child.waitUntilExit()
}

func command(_ executable: String,_ arguments: [String], timeout: Double = 5) throws -> CommandResult {
    let child=Process(),pipe=Pipe()
    child.executableURL=URL(fileURLWithPath:executable);child.arguments=arguments
    child.standardOutput=pipe;child.standardError=pipe;child.standardInput=FileHandle.nullDevice
    try child.run()
    // Read incrementally so even a verbose launchctl cannot fill the pipe.
    let fd=pipe.fileHandleForReading.fileDescriptor
    _=fcntl(fd,F_SETFL,O_NONBLOCK)
    var data=Data();let deadline=ProcessInfo.processInfo.systemUptime+timeout
    while child.isRunning {
        var buffer=[UInt8](repeating:0,count:4096)
        let count=Darwin.read(fd,&buffer,buffer.count)
        if count>0,data.count<1024*1024 { data.append(contentsOf:buffer.prefix(count)) }
        if ProcessInfo.processInfo.systemUptime>=deadline {
            stopChild(child);throw NativeError.invalid("command timed out: \(executable)")
        }
        Thread.sleep(forTimeInterval:0.01)
    }
    child.waitUntilExit()
    while true {
        var buffer=[UInt8](repeating:0,count:4096);let count=Darwin.read(fd,&buffer,buffer.count)
        if count<=0 { break };if data.count<1024*1024 { data.append(contentsOf:buffer.prefix(count)) }
    }
    try? pipe.fileHandleForReading.close();try? pipe.fileHandleForWriting.close()
    return CommandResult(status:child.terminationStatus,output:String(decoding:data,as:UTF8.self))
}

func readReady(_ pipe: Pipe, child: Process, deadline: Double, stopped: ()->Bool) throws -> [String:Any] {
    var data=Data();let fd=pipe.fileHandleForReading.fileDescriptor
    while data.count<65536 {
        if stopped() { throw SessionCancelled() }
        guard child.isRunning else { throw NativeError.invalid("virtual display host exited before ready") }
        guard ProcessInfo.processInfo.systemUptime<deadline else { throw NativeError.invalid("virtual display creation deadline exceeded") }
        var item=pollfd(fd:fd,events:Int16(POLLIN),revents:0)
        if poll(&item,1,50)>0 {
            var byte:UInt8=0
            guard Darwin.read(fd,&byte,1)==1 else { throw NativeError.invalid("virtual display ready stream closed") }
            if byte==10 {
                guard let row=try JSONSerialization.jsonObject(with:data) as? [String:Any],row["event"] as? String == "ready"
                else { throw NativeError.invalid("invalid virtual display ready record") }
                return row
            }
            data.append(byte)
        }
    }
    throw NativeError.invalid("oversized virtual display ready record")
}

final class SessionLock {
    private var fd: Int32 = -1
    init(_ directory: URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        fd=open(directory.appendingPathComponent("owner.lock").path,O_CREAT|O_RDWR|O_CLOEXEC,0o600)
        guard fd>=0 else { throw NativeError.invalid("cannot open session lock") }
        if flock(fd,LOCK_EX|LOCK_NB) != 0 { close(fd);fd = -1;throw NativeError.invalid("a desktop session is already running") }
    }
    deinit { if fd>=0 { close(fd) } }
}

final class StopSignal: @unchecked Sendable {
    private let lock=NSLock()
    private var flag=false
    private var sources=[DispatchSourceSignal]()
    var requested: Bool { lock.lock();defer{lock.unlock()};return flag }
    init() {
        for number in [SIGTERM,SIGINT] {
            signal(number,SIG_IGN)
            let source=DispatchSource.makeSignalSource(signal:number,queue:.global())
            source.setEventHandler { [weak self] in self?.request() };source.resume();sources.append(source)
        }
    }
    func request() { lock.lock();flag=true;lock.unlock() }
    deinit { for source in sources { source.cancel() } }
}

final class VendorOwnership {
    static var label: String { "gui/\(getuid())/com.racer.usbdisplay" }
    private var stopped=false
    static func loaded() throws -> Bool { try command("/bin/launchctl",["print",label]).status==0 }
    func acquire(takeover: Bool) throws {
        if try Self.loaded() {
            guard takeover else { throw NativeError.invalid("vendor owns USB; takeover required") }
            let result=try command("/bin/launchctl",["bootout",Self.label])
            guard result.status==0 else { throw NativeError.invalid("vendor bootout failed: \(result.output)") }
            stopped=true
        }
        let deadline=ProcessInfo.processInfo.systemUptime+3
        while try command("/usr/bin/pgrep",["-x","UsbDisplay"]).status==0 {
            guard ProcessInfo.processInfo.systemUptime<deadline else { throw NativeError.invalid("UsbDisplay still running; refusing interface contention") }
            Thread.sleep(forTimeInterval:0.1)
        }
    }
    func restore() throws {
        guard stopped else { return }
        let result=try command("/bin/launchctl",["bootstrap","gui/\(getuid())","/Library/LaunchAgents/com.racer.usbdisplay.plist"])
        guard try Self.loaded() else { throw NativeError.invalid("vendor restoration failed: \(result.output)") }
        stopped=false
    }
}
