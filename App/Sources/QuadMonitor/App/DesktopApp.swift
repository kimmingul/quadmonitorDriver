import AppKit
import Foundation
import CoreGraphics

@MainActor
final class DesktopApp: NSObject, NSApplicationDelegate {
    private var config: DesktopAppConfiguration
    private var item: NSStatusItem!
    private let menu=NSMenu()
    private var stateItem: NSMenuItem!
    private var startItem: NSMenuItem!
    private var stopItem: NSMenuItem!
    private var demoItem: NSMenuItem!
    private var rates: [NSMenuItem]=[]
    private var panels: [NSMenuItem]=[]
    private var process: Process?
    private var timer: Timer?
    private var output: FileHandle?
    private var lastLog: URL?
    private var runDirectory: URL?
    private var stopPath: String?
    private var stopping=false
    private var quitting=false
    private var recovery=DesktopRecovery()
    private var disconnected=false
    private var presenceProcess: Process?
    private var presenceOutput: Pipe?
    private var presenceStarted=0.0
    private var nextPresenceCheck=0.0
    private var message=AppMessage(.idle)
    private var text: AppText
    private var languagePopup=NSPopUpButton()
    private var localizedMenus: [(NSMenuItem,AppText.Key)]=[]
    private var localizedButtons: [(NSButton,AppText.Key)]=[]
    private var localizedLabels: [(NSTextField,AppText.Key)]=[]
    private var panelStats: [String:[String:Any]]?
    private var window: NSWindow?
    private let windowStatus=NSTextField(wrappingLabelWithString:"")
    private let windowPanels=NSTextField(wrappingLabelWithString:"")
    private var startButton: NSButton!
    private var stopButton: NSButton!
    private var demoButton: NSButton!
    private var ratePopup=NSPopUpButton()
    private var settingsView=DesktopSettingsView(frame:.zero)

    init(config: DesktopAppConfiguration) { self.config=config;self.text=AppText(choice:config.language) }

    static func run(_ config: DesktopAppConfiguration) {
        let app=NSApplication.shared
        app.setActivationPolicy(.accessory)
        let controller=DesktopApp(config:config)
        app.delegate=controller
        withExtendedLifetime(controller) { app.run() }
    }

    private func entry(_ title: String,_ action: Selector?) -> NSMenuItem {
        let row=NSMenuItem(title:title,action:action,keyEquivalent:"")
        row.target=self;menu.addItem(row);return row
    }

    private func translatedEntry(_ key: AppText.Key,_ action: Selector?) -> NSMenuItem {
        let row=entry(text(key),action);localizedMenus.append((row,key));return row
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        item=NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.title="Quad ○"
        item.button?.setAccessibilityLabel("Quad Monitor")
        item.menu=menu;menu.autoenablesItems=false
        stateItem=entry(message.render(text),nil);stateItem.isEnabled=false
        for name in text.panelNames {
            let row=entry(text(.panelWaiting,name),nil);row.isEnabled=false;panels.append(row)
        }
        menu.addItem(.separator())
        startItem=translatedEntry(.start,#selector(start))
        stopItem=translatedEntry(.stop,#selector(stop));stopItem.isEnabled=false
        demoItem=translatedEntry(.demo,#selector(toggleDemo))
        for fps in [2,10,30,60] {
            let row=entry(text(.rateMenu,fps),#selector(changeRate(_:)))
            row.tag=fps;rates.append(row)
        }
        menu.addItem(.separator())
        _=translatedEntry(.showWindow,#selector(showWindow))
        _=translatedEntry(.permissionSettings,#selector(openPermissions))
        _=translatedEntry(.logs,#selector(openLogs))
        _=translatedEntry(.quit,#selector(quit))
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(willSleep),name:NSWorkspace.willSleepNotification,object:nil)
        NSWorkspace.shared.notificationCenter.addObserver(self,selector:#selector(didWake),name:NSWorkspace.didWakeNotification,object:nil)
        timer=Timer.scheduledTimer(withTimeInterval:0.5,repeats:true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer!,forMode:.common)
        createWindow();showWindow()
        refresh()
        if config.startImmediately { start() }
    }

    private func createWindow() {
        let w=NSWindow(contentRect:NSRect(x:0,y:0,width:650,height:800),
                       styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
        w.title="Quad Monitor";w.isReleasedWhenClosed=false;w.center()
        let title=NSTextField(labelWithString:text(.windowTitle))
        title.font = .boldSystemFont(ofSize:20)
        windowStatus.font = .systemFont(ofSize:14)
        windowPanels.font = .monospacedDigitSystemFont(ofSize:12,weight:.regular)
        startButton=NSButton(title:text(.start),target:self,action:#selector(start))
        stopButton=NSButton(title:text(.stop),target:self,action:#selector(stop))
        demoButton=NSButton(checkboxWithTitle:text(.demo),target:self,action:#selector(toggleDemo))
        for fps in [2,10,30,60] { ratePopup.addItem(withTitle:text(.rate,fps));ratePopup.lastItem?.tag=fps }
        ratePopup.target=self;ratePopup.action=#selector(changePopup)
        ratePopup.widthAnchor.constraint(equalToConstant:145).isActive=true
        let quitButton=NSButton(title:text(.quit),target:self,action:#selector(quit))
        let buttons=NSStackView(views:[startButton,stopButton,quitButton]);buttons.orientation = .horizontal
        let options=NSStackView(views:[ratePopup,demoButton]);options.orientation = .horizontal
        let logs=NSButton(title:text(.runLogs),target:self,action:#selector(openLogs))
        let permissions=NSButton(title:text(.permission),target:self,action:#selector(openPermissions))
        let links=NSStackView(views:[logs,permissions]);links.orientation = .horizontal
        settingsView.changed = { [weak self] panels, performance in
            guard let self, self.process == nil, !self.recovery.waiting else { return }
            self.config.selectedPanels=panels;self.config.performance=performance;self.saveSettings();self.refresh()
        }
        let languageLabel=NSTextField(labelWithString:text(.language))
        languagePopup.target=self;languagePopup.action=#selector(changeLanguage)
        languagePopup.widthAnchor.constraint(equalToConstant:200).isActive=true
        let languageRow=NSStackView(views:[languageLabel,languagePopup]);languageRow.orientation = .horizontal
        localizedLabels=[(title,.windowTitle),(languageLabel,.language)]
        localizedButtons=[(startButton,.start),(stopButton,.stop),(demoButton,.demo),
                          (quitButton,.quit),(logs,.runLogs),(permissions,.permission)]
        localize()
        let stack=NSStackView(views:[title,windowStatus,windowPanels,buttons,languageRow,options,settingsView,links])
        stack.orientation = .vertical;stack.alignment = .leading;stack.spacing=18
        stack.translatesAutoresizingMaskIntoConstraints=false;w.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:w.contentView!.leadingAnchor,constant:24),
            stack.trailingAnchor.constraint(equalTo:w.contentView!.trailingAnchor,constant:-24),
            stack.topAnchor.constraint(equalTo:w.contentView!.topAnchor,constant:24)])
        window=w
    }
    private func localize() {
        for (row,key) in localizedMenus { row.title=text(key) }
        for (button,key) in localizedButtons { button.title=text(key) }
        for (label,key) in localizedLabels { label.stringValue=text(key) }
        for row in rates { row.title=text(.rateMenu,row.tag) }
        for row in ratePopup.itemArray { row.title=text(.rate,row.tag) }
        languagePopup.removeAllItems()
        languagePopup.addItems(withTitles:[text(.systemLanguage),"한국어","English","中文（简体）"])
        languagePopup.selectItem(at:AppLanguage.allCases.firstIndex(of:config.language) ?? 0)
        settingsView.localize(text)
    }
    @objc private func changeLanguage() {
        guard let choice=AppLanguage.allCases.indices.contains(languagePopup.indexOfSelectedItem)
            ? AppLanguage.allCases[languagePopup.indexOfSelectedItem] : nil else { return }
        config.language=choice;text=AppText(choice:choice)
        saveSettings()
        // Recreate the controls, not the capture session. Native pop-up cells
        // cache title drawing across language changes; fresh cells avoid stale
        // partial titles while preserving the control window's position.
        let frame=window?.frame
        window?.close()
        languagePopup=NSPopUpButton();ratePopup=NSPopUpButton()
        settingsView=DesktopSettingsView(frame:.zero)
        createWindow()
        if let frame { window?.setFrame(frame,display:true) }
        refresh();showWindow()
    }
    @objc private func showWindow() { window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true) }
    private func saveSettings() {
        do { try config.savePreferences() } catch { message = .init(.saveFailed,error.localizedDescription) }
    }
    @objc private func changePopup() { config.fps=ratePopup.selectedItem?.tag ?? 2;saveSettings();refresh() }

    @objc private func start() {
        guard process == nil else { return }
        recovery.startRequested();recordRecovery("start_requested")
        launchSession()
    }

    private func launchSession() {
        guard process == nil, !quitting, !recovery.sleeping else { return }
        guard CGPreflightScreenCaptureAccess() else {
            _=CGRequestScreenCaptureAccess()
            recovery.stopRequested()
            message = .init(.permissionRequired)
            refresh();return
        }
        do {
            let fm=FileManager.default
            guard fm.isExecutableFile(atPath:config.coordinator.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            try fm.createDirectory(at:config.controlDirectory,withIntermediateDirectories:true)
            let log=config.controlDirectory.appendingPathComponent("app-\(UUID().uuidString).log")
            fm.createFile(atPath:log.path,contents:nil)
            let handle=try FileHandle(forWritingTo:log)
            let child=Process();child.executableURL=config.coordinator
            child.arguments=config.workerArguments(ownerPID:ProcessInfo.processInfo.processIdentifier)
            child.currentDirectoryURL=config.resources
            child.standardOutput=handle;child.standardError=handle
            child.standardInput=FileHandle.nullDevice
            try child.run()
            recovery.sessionStarted();disconnected=false
            output=handle;lastLog=log;runDirectory=nil;process=child;stopping=false;stopPath=nil
            recordRecovery("session_started",["coordinator_pid":Int(child.processIdentifier),"fps":config.fps])
            panelStats=nil
            message = .init(.starting,config.selectedPanels.count)
        } catch { recovery.stopRequested();message = .init(.startFailed,error.localizedDescription) }
        refresh()
    }

    @objc private func stop() {
        recovery.stopRequested();cancelPresence();recordRecovery("stop_requested")
        requestSessionStop()
        if process == nil { message = .init(.stoppedCancelled);refresh() }
    }

    private func requestSessionStop() {
        guard let process,process.isRunning,!stopping else { return }
        stopping=true;message = .init(.stopping)
        if let stopPath {
            do { try Data().write(to:URL(fileURLWithPath:stopPath),options:.atomic) }
            catch { message = .init(.stopFailed,error.localizedDescription);process.terminate() }
        } else { process.terminate() }
        refresh()
    }

    @objc private func willSleep() {
        recovery.willSleep();cancelPresence();recordRecovery("will_sleep")
        requestSessionStop()
    }
    @objc private func didWake() { recovery.didWake();recordRecovery("did_wake");nextPresenceCheck=0;refresh() }
    @objc private func toggleDemo() { config.demo.toggle();saveSettings();refresh() }
    @objc private func changeRate(_ sender: NSMenuItem) { config.fps=sender.tag;saveSettings();refresh() }
    @objc private func openLogs() {
        if let runDirectory { NSWorkspace.shared.open(runDirectory) }
        else if let lastLog { NSWorkspace.shared.activateFileViewerSelecting([lastLog]) }
        else {
            try? FileManager.default.createDirectory(at:config.logsDirectory,withIntermediateDirectories:true)
            NSWorkspace.shared.open(config.logsDirectory)
        }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openPermissions() {
        if let url=URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        quitting=true;recovery.stopRequested();cancelPresence();recordRecovery("quit_requested")
        if process?.isRunning == true {
            requestSessionStop();return .terminateLater
        }
        return .terminateNow
    }

    private func recordRecovery(_ event: String, _ values: [String:Any] = [:]) {
        let directory=config.controlDirectory
        try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let path=directory.appendingPathComponent("recovery-\(ProcessInfo.processInfo.processIdentifier).jsonl")
        if !FileManager.default.fileExists(atPath:path.path) { FileManager.default.createFile(atPath:path.path,contents:nil) }
        var row=values;row["event"]=event;row["unix"]=Date().timeIntervalSince1970
        row["requested"]=recovery.requested;row["waiting"]=recovery.waiting;row["sleeping"]=recovery.sleeping
        if let data=try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys),
           let handle=try? FileHandle(forWritingTo:path) {
            defer { try? handle.close() }
            _=try? handle.seekToEnd();try? handle.write(contentsOf:data+Data([10]))
        }
    }

    private func cancelPresence() {
        if presenceProcess?.isRunning == true { presenceProcess?.terminate() }
        presenceProcess=nil;presenceOutput=nil
    }

    private func checkRecovery() {
        guard process == nil, recovery.waiting, !recovery.sleeping, !quitting else { return }
        let now=ProcessInfo.processInfo.systemUptime
        if let probe=presenceProcess {
            if probe.isRunning {
                if now-presenceStarted>8 { probe.terminate() }
                return
            }
            let data=presenceOutput?.fileHandleForReading.readDataToEndOfFile()
            presenceProcess=nil;presenceOutput=nil;nextPresenceCheck=now+2
            let row=data.flatMap { (try? JSONSerialization.jsonObject(with:$0)) as? [String:Any] }
            if probe.terminationStatus==0, recovery.shouldResume(devicesReady:row?["ready"] as? Bool == true) {
                recordRecovery("devices_ready_resume");launchSession()
            }
            return
        }
        guard now>=nextPresenceCheck else { return }
        let probe=Process(),pipe=Pipe()
        probe.executableURL=config.coordinator
        probe.arguments=config.presenceArguments
        probe.currentDirectoryURL=config.resources
        probe.standardOutput=pipe;probe.standardError=FileHandle.nullDevice;probe.standardInput=FileHandle.nullDevice
        do { try probe.run();presenceProcess=probe;presenceOutput=pipe;presenceStarted=now }
        catch { nextPresenceCheck=now+2 }
    }

    private func refresh() {
        let running=process?.isRunning == true
        if let process {
            let statusURL=config.controlDirectory.appendingPathComponent("status.json")
            if let data=try? Data(contentsOf:statusURL),
               let row=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],
               let pid=row["pid"] as? Int,pid==Int(process.processIdentifier) {
                if let directory=row["directory"] as? String { runDirectory=URL(fileURLWithPath:directory) }
                stopPath=row["stop_file"] as? String
                if row["termination_reason"] as? String == "usb_disconnected" { disconnected=true }
                if !stopping {
                    switch row["state"] as? String {
                    case "running":message = .init(.running,config.selectedPanels.count)
                    case "starting":message = .init(.starting,config.selectedPanels.count)
                    case "stopping":message = .init(.stopping)
                    case "failed":message = .init(.error,(row["error"] as? String) ?? text(.checkLogs))
                    default:break
                    }
                }
                if let stats=row["panels"] as? [String:[String:Any]] { panelStats=stats }
            }
            if !running {
                let code=process.terminationStatus
                recovery.sessionEnded(disconnected:disconnected)
                recordRecovery("session_ended",["exit_code":Int(code),"disconnected":disconnected])
                self.process=nil;try? output?.close();output=nil;stopPath=nil;stopping=false
                message=code==0 ? .init(.stopped) : .init(.runFailed,Int(code))
                if quitting { NSApp.reply(toApplicationShouldTerminate:true) }
            }
        }
        if recovery.waiting { message=recovery.sleeping ? .init(.sleeping) : .init(.reconnecting) }
        checkRecovery()
        let active=process?.isRunning == true
        let waiting=recovery.waiting
        settingsView.refresh(panels:config.selectedPanels,options:config.performance,enabled:!active && !waiting)
        for (index,role) in ["right","left","top"].enumerated() where index < panels.count {
            let name=text.panelNames[index]
            if !config.selectedPanels.contains(role) { panels[index].title=text(.panelDisabled,name) }
            else if let stats=panelStats {
                panels[index].title=text(.panelStats,name,stats[role]?["frames"] as? Int ?? 0,
                                         stats[role]?["average_updates_per_second"] as? Double ?? 0)
            } else { panels[index].title=text(active ? .panelPreparing : .panelWaiting,name) }
        }
        stateItem?.title=message.render(text)
        windowStatus.stringValue=message.render(text)
        windowPanels.stringValue=panels.map(\.title).joined(separator:"\n")
        startButton?.isEnabled = !active && !waiting;stopButton?.isEnabled = (active && !stopping) || waiting
        demoButton?.isEnabled = !active && !waiting;demoButton?.state=config.demo ? .on : .off
        ratePopup.isEnabled = !active && !waiting;ratePopup.selectItem(withTag:config.fps)
        item?.button?.title=active ? (stopping ? "Quad …" : "Quad ●") : (waiting ? "Quad ↻" : "Quad ○")
        startItem?.isEnabled = !active && !waiting
        stopItem?.isEnabled = (active && !stopping) || waiting
        demoItem?.isEnabled = !active && !waiting;demoItem?.state=config.demo ? .on : .off
        for row in rates { row.isEnabled = !active && !waiting;row.state=row.tag==config.fps ? .on : .off }
    }
}
