import Foundation

enum AppLanguage: String, Codable, CaseIterable, Sendable {
    case system, korean, english, chinese
    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        switch self {
        case .korean: return "ko"
        case .english: return "en"
        case .chinese: return "zh-Hans"
        case .system:
            // The requested fallback applies to the primary language, not a
            // later supported language in the preference list.
            let primary = preferredLanguages.first?.replacingOccurrences(of:"_",with:"-")
                .lowercased().split(separator:"-").first.map(String.init) ?? "en"
            switch primary { case "ko": return "ko"; case "zh": return "zh-Hans"; default: return "en" }
        }
    }
}

struct AppText {
    enum Key: String, CaseIterable {
        case idle, right, left, top, panelWaiting, panelPreparing, panelDisabled, panelStats, start, stop, demo, rateMenu, rate, showWindow, permissionSettings, logs, runLogs, quit, windowTitle, permission, saveFailed, permissionRequired, starting, startFailed, stoppedCancelled, stopping, stopFailed, running, error, checkLogs, stopped, runFailed, sleeping, reconnecting, screens, screenNote, cpu, workerOne, workerCount, workersAuto, damage, gpu, timing, periodic, arrival, compression, delta, full, queue, frameCount, reuse, adaptive, overlap, settingsNote, language, systemLanguage
    }
    let language: String
    private let bundle: Bundle
    static let resourceBundle: Bundle = {
        // The installed app must work without the Swift build directory.
        if let url=Bundle.main.resourceURL?.appendingPathComponent("QuadMonitor_QuadMonitor.bundle"),
           let bundled=Bundle(url:url) { return bundled }
        return Bundle.module
    }()
    init(choice: AppLanguage = .system, preferredLanguages: [String] = Locale.preferredLanguages) {
        language=choice.resolved(preferredLanguages:preferredLanguages)
        bundle=Bundle(path:Self.resourceBundle.path(forResource:language.lowercased(),ofType:"lproj")!)!
    }
    func callAsFunction(_ key: Key, _ arguments: CVarArg...) -> String {
        format(key, arguments)
    }
    func format(_ key: Key, _ arguments: [CVarArg]) -> String {
        let value=bundle.localizedString(forKey:key.rawValue,value:nil,table:nil)
        return String(format:value,locale:Locale(identifier:language),arguments:arguments)
    }
    var panelNames: [String] { [self(.right),self(.left),self(.top)] }
}

struct AppMessage {
    let key: AppText.Key
    let arguments: [CVarArg]
    init(_ key: AppText.Key, _ arguments: CVarArg...) { self.key=key;self.arguments=arguments }
    func render(_ text: AppText) -> String { text.format(key,arguments) }
}
