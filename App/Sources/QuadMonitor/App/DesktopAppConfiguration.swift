import Foundation
import VerifiedDisplayCore

struct DesktopAppConfiguration: Sendable {
    enum Invalid: Error { case argument(String), missingPaths }
    let resources: URL
    let coordinator: URL
    var fps: Int
    var demo: Bool
    let startImmediately: Bool
    let dataRoot: URL
    var selectedPanels: [String] = ["right","left","top"]
    var language: AppLanguage = .system
    var performance = PerformanceOptions(workers:1,scheduling:.arrival)

    private struct Preferences: Codable { var fps: Int; var demo: Bool; var panels: [String]; var performance: PerformanceOptions; var language: AppLanguage? }
    static func validPanels(_ panels: [String]) -> Bool { !panels.isEmpty && Set(panels).count==panels.count && Set(panels).isSubset(of:["right","left","top"]) }
    func savePreferences() throws {
        try FileManager.default.createDirectory(at:controlDirectory,withIntermediateDirectories:true)
        try JSONEncoder().encode(Preferences(fps:fps,demo:demo,panels:selectedPanels,performance:performance,language:language))
            .write(to:controlDirectory.appendingPathComponent("preferences.json"),options:.atomic)
    }
    var controlDirectory: URL { dataRoot.appendingPathComponent("control") }
    var logsDirectory: URL { dataRoot.appendingPathComponent("runs") }
    static func bundledDefaults(bundle: URL, support: URL) -> [String:String] {
        ["resources":bundle.appendingPathComponent("Contents/Resources").path,
         "coordinator":bundle.appendingPathComponent("Contents/Helpers/VerifiedSession").path,
         "data_root":support.appendingPathComponent("Quad Monitor").path]
    }
    var presenceArguments: [String] {
        ["--resources",resources.path,"--control-dir",controlDirectory.path,
         "--device-presence","--panels",selectedPanels.joined(separator:",")]
    }

    static func parse(_ args: [String], defaults: [String:String]) throws -> Self {
        var root=defaults["resources"], coordinator=defaults["coordinator"], dataRoot=defaults["data_root"]
        var fps=60, demo=false, start=false
        var seen=Set<String>()
        for arg in args.dropFirst() {
            let key=String(arg.split(separator:"=",maxSplits:1)[0])
            guard seen.insert(key).inserted else { throw Invalid.argument(arg) }
            switch arg {
            case "--desktop-app":continue
            case "--start":start=true
            case "--demo":demo=true
            default:
                let pair=arg.split(separator:"=",maxSplits:1,omittingEmptySubsequences:false)
                guard pair.count==2, !pair[1].isEmpty else { throw Invalid.argument(arg) }
                switch pair[0] {
                case "--resources":root=String(pair[1])
                case "--coordinator":coordinator=String(pair[1])
                case "--data-root":dataRoot=String(pair[1])
                case "--fps":
                    guard let n=Int(pair[1]),(1...60).contains(n) else { throw Invalid.argument(arg) }
                    fps=n
                default:throw Invalid.argument(arg)
                }
            }
        }
        guard let root,let coordinator,let dataRoot,
              root.hasPrefix("/"),coordinator.hasPrefix("/"),dataRoot.hasPrefix("/") else { throw Invalid.missingPaths }
        var config=Self(resources:URL(fileURLWithPath:root),coordinator:URL(fileURLWithPath:coordinator),
                        fps:fps,demo:demo,startImmediately:start,dataRoot:URL(fileURLWithPath:dataRoot))
        if let data=try? Data(contentsOf:config.controlDirectory.appendingPathComponent("preferences.json")),
           let saved=try? JSONDecoder().decode(Preferences.self,from:data),
           (1...60).contains(saved.fps), validPanels(saved.panels), saved.performance.isValid {
            if !seen.contains("--fps") { config.fps=saved.fps }
            if !seen.contains("--demo") { config.demo=saved.demo }
            config.selectedPanels=saved.panels;config.performance=saved.performance;config.language=saved.language ?? .system
        }
        return config
    }

    func workerArguments(ownerPID: Int32? = nil) -> [String] {
        ["--resources",resources.path,
         "--run","--send","--continuous","--takeover-vendor","--fps",String(fps)] +
        ["--panels",selectedPanels.joined(separator:",")] + performance.arguments +
        (demo ? ["--demo"] : []) + (ownerPID.map { ["--owner-pid",String($0)] } ?? []) +
        ["--control-dir",controlDirectory.path]
    }
}
