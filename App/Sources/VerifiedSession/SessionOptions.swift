import Foundation
import VerifiedDisplayCore
import VerifiedUSB

struct SessionOptions {
    var resources: URL
    var host: URL
    var capture: URL
    var control: URL
    var mapping: URL
    var roles=["right","left","top"]
    var fps=60,seconds=30
    var run=false,send=false,continuous=false,demo=false,takeover=false,devicePresence=false,runtimeCheck=false
    var ownerPID: Int32?
    var performance=PerformanceOptions(workers:1,scheduling:.arrival)
    var runs: URL { control.deletingLastPathComponent().appendingPathComponent("runs") }

    init(_ args: [String], executable: URL) throws {
        let contents=executable.deletingLastPathComponent().deletingLastPathComponent()
        resources=contents.appendingPathComponent("Resources")
        host=executable.deletingLastPathComponent().appendingPathComponent("VerifiedDesktopHost")
        capture=executable.deletingLastPathComponent().appendingPathComponent("VerifiedCapture")
        control=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Quad Monitor/control")
        mapping=resources.appendingPathComponent("panel-layout.json")
        var values=[String:String](),flags=Set<String>();var i=0
        let switches: Set<String>=["--run","--send","--continuous","--demo","--takeover-vendor","--device-presence","--runtime-check"]
        let pairs: Set<String>=["--resources","--host","--capture","--control-dir","--mapping","--panels","--fps","--seconds",
              "--owner-pid","--encoder-workers","--scheduling","--damage","--compression","--queue-depth",
              "--reuse-buffers","--adaptive-workers","--overlap-preparation"]
        while i<args.count {
            let key=args[i]
            guard !flags.contains(key),values[key]==nil else { throw NativeError.invalid("duplicate option: \(key)") }
            if switches.contains(key) { flags.insert(key);i+=1 }
            else {
                guard pairs.contains(key),i+1<args.count else { throw NativeError.invalid("invalid option: \(key)") }
                values[key]=args[i+1];i+=2
            }
        }
        func integer(_ key: String,_ fallback: Int) throws -> Int {
            guard let text=values[key] else { return fallback }
            guard let number=Int(text) else { throw NativeError.invalid("invalid integer: \(key)") };return number
        }
        if let path=values["--resources"] { resources=URL(fileURLWithPath:path) }
        if let path=values["--host"] { host=URL(fileURLWithPath:path) }
        if let path=values["--capture"] { capture=URL(fileURLWithPath:path) }
        if let path=values["--control-dir"] { control=URL(fileURLWithPath:path) }
        let custom=control.deletingLastPathComponent().appendingPathComponent("panel-layout.json")
        mapping=values["--mapping"].map { URL(fileURLWithPath:$0) } ??
            (FileManager.default.fileExists(atPath:custom.path) ? custom : resources.appendingPathComponent("panel-layout.json"))
        if let text=values["--panels"] { roles=text.components(separatedBy:",") }
        guard !roles.isEmpty,Set(roles).count==roles.count,Set(roles).isSubset(of:PanelMapping.roles) else { throw NativeError.invalid("invalid selected panels") }
        fps=try integer("--fps",60);seconds=try integer("--seconds",30)
        guard (1...60).contains(fps),(2...3600).contains(seconds) else { throw NativeError.invalid("fps=1..60 and seconds=2..3600 required") }
        if values["--owner-pid"] != nil {
            guard let pid=Int32(exactly:try integer("--owner-pid",0)),pid>0,pid==getppid() else { throw NativeError.invalid("owner must be direct parent") }
            ownerPID=pid
        }
        performance.workers=try integer("--encoder-workers",1)
        if let v=values["--scheduling"] { guard let s=PerformanceOptions.Scheduling(rawValue:v) else { throw NativeError.invalid("scheduling") };performance.scheduling=s }
        if let v=values["--damage"] { guard let s=PerformanceOptions.Damage(rawValue:v) else { throw NativeError.invalid("damage") };performance.damage=s }
        if let v=values["--compression"] { guard let s=PerformanceOptions.Compression(rawValue:v) else { throw NativeError.invalid("compression") };performance.compression=s }
        performance.queueDepth=try integer("--queue-depth",3)
        for key in ["--reuse-buffers","--adaptive-workers","--overlap-preparation"] {
            let v=try integer(key,0);guard v==0 || v==1 else { throw NativeError.invalid(key) }
            if key=="--reuse-buffers" { performance.reuseBuffers=v==1 }
            if key=="--adaptive-workers" { performance.adaptiveWorkers=v==1 }
            if key=="--overlap-preparation" { performance.overlapPreparation=v==1 }
        }
        guard performance.isValid else { throw NativeError.invalid("performance options") }
        run=flags.contains("--run");send=flags.contains("--send");continuous=flags.contains("--continuous")
        demo=flags.contains("--demo");takeover=flags.contains("--takeover-vendor");devicePresence=flags.contains("--device-presence")
        runtimeCheck=flags.contains("--runtime-check")
        guard run || (!send && !continuous) else { throw NativeError.invalid("send/continuous require run") }
        if continuous { seconds=0 }
    }
    func selectedMapping() throws -> [PanelMapping] {
        struct Document: Decodable { var panels: [PanelMapping] }
        return try PanelMapping.select(JSONDecoder().decode(Document.self,from:Data(contentsOf:mapping)).panels,roles:roles)
    }
}
