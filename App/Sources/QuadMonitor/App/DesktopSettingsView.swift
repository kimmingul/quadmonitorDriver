import AppKit
import VerifiedDisplayCore

@MainActor
final class DesktopSettingsView: NSStackView {
    var changed: (([String],PerformanceOptions)->Void)?
    private var roles: [NSButton]=[]
    private let workers=NSPopUpButton(),damage=NSPopUpButton(),scheduling=NSPopUpButton()
    private let compression=NSPopUpButton(),depth=NSPopUpButton()
    private var algorithms: [NSButton]=[]
    private var labels: [(NSTextField,AppText.Key)]=[]
    private var options=PerformanceOptions()
    private var lastRefresh: (panels:[String],options:PerformanceOptions,enabled:Bool)?
    private let names=["right","left","top"]
    override init(frame: NSRect) {
        super.init(frame:frame);orientation = .vertical;alignment = .leading;spacing=10
        let screens=NSStackView();screens.orientation = .horizontal
        for i in 0..<3 {
            let button=NSButton(checkboxWithTitle:"",target:self,action:#selector(updateSelection))
            button.tag=i;roles.append(button);screens.addArrangedSubview(button)
        }
        addArrangedSubview(label(.screens));addArrangedSubview(screens)
        let screenNote=label(.screenNote,wrap:true)
        screenNote.font = .systemFont(ofSize:11);addArrangedSubview(screenNote)
        row(.cpu,workers);row(.damage,damage);row(.timing,scheduling)
        row(.compression,compression);row(.queue,depth)
        for _ in 0..<3 {
            let button=NSButton(checkboxWithTitle:"",target:self,action:#selector(updateSelection))
            algorithms.append(button);addArrangedSubview(button)
        }
        let note=label(.settingsNote,wrap:true)
        note.font = .systemFont(ofSize:11);note.textColor = .secondaryLabelColor;addArrangedSubview(note)
        localize(AppText())
    }
    required init?(coder:NSCoder) { fatalError("init(coder:) not supported") }
    private func label(_ key:AppText.Key,wrap:Bool=false) -> NSTextField {
        let field=wrap ? NSTextField(wrappingLabelWithString:"") : NSTextField(labelWithString:"")
        labels.append((field,key));return field
    }
    private func row(_ key:AppText.Key,_ popup:NSPopUpButton) {
        popup.target=self;popup.action=#selector(updateSelection)
        popup.widthAnchor.constraint(equalToConstant:320).isActive=true
        let title=label(key);title.widthAnchor.constraint(equalToConstant:135).isActive=true
        let line=NSStackView(views:[title,popup]);line.orientation = .horizontal
        addArrangedSubview(line)
    }
    func localize(_ text:AppText) {
        for (field,key) in labels { field.stringValue=text(key) }
        for (button,title) in zip(roles,text.panelNames) { button.title=title }
        for (button,key) in zip(algorithms,[AppText.Key.reuse,.adaptive,.overlap]) { button.title=text(key) }
        func update(_ popup:NSPopUpButton,_ titles:[String]) {
            let selected=max(0,popup.indexOfSelectedItem)
            if popup.numberOfItems == titles.count {
                for (item,title) in zip(popup.itemArray,titles) { item.title=title }
            } else { popup.removeAllItems();popup.addItems(withTitles:titles) }
            popup.selectItem(at:selected)
            popup.synchronizeTitleAndSelectedItem();popup.needsDisplay=true
        }
        update(workers,[text(.workerOne)] + [2,4,8].map{text(.workerCount,$0)} + [text(.workersAuto)])
        update(damage,["CPU",text(.gpu)])
        update(scheduling,[text(.periodic),text(.arrival)])
        update(compression,[text(.delta),text(.full)])
        update(depth,[2,3,5].map{text(.frameCount,$0)})
        damage.item(at:1)?.isEnabled=MetalTileDiffer.available
    }
    func refresh(panels:[String],options:PerformanceOptions,enabled:Bool) {
        if let lastRefresh, lastRefresh.panels==panels, lastRefresh.options==options, lastRefresh.enabled==enabled { return }
        lastRefresh=(panels,options,enabled)
        self.options=options
        for button in roles {
            let selected=panels.contains(names[button.tag]);button.state=selected ? .on : .off
            button.isEnabled=enabled && !(selected && panels.count==1)
        }
        workers.selectItem(at:[1,2,4,8,0].firstIndex(of:options.workers) ?? 0)
        damage.selectItem(at:options.damage == .metal ? 1 : 0)
        scheduling.selectItem(at:options.scheduling == .arrival ? 1 : 0)
        compression.selectItem(at:options.compression == .full ? 1 : 0)
        depth.selectItem(at:[2,3,5].firstIndex(of:options.queueDepth) ?? 1)
        for popup in [workers,damage,scheduling,compression,depth] { popup.isEnabled=enabled }
        for (button,value) in zip(algorithms,[options.reuseBuffers,options.adaptiveWorkers,options.overlapPreparation]) {
            button.state=value ? .on : .off; button.isEnabled=enabled
        }
        damage.item(at:1)?.isEnabled=MetalTileDiffer.available
    }
    @objc private func updateSelection() {
        let selected=roles.filter{$0.state == .on}.map{names[$0.tag]}
        guard !selected.isEmpty else { return }
        options.workers=[1,2,4,8,0][workers.indexOfSelectedItem]
        options.damage=damage.indexOfSelectedItem==1 ? .metal : .cpu
        options.scheduling=scheduling.indexOfSelectedItem==1 ? .arrival : .periodic
        options.compression=compression.indexOfSelectedItem==1 ? .full : .delta
        options.queueDepth=[2,3,5][depth.indexOfSelectedItem]
        options.reuseBuffers=algorithms[0].state == .on
        options.adaptiveWorkers=algorithms[1].state == .on
        options.overlapPreparation=algorithms[2].state == .on
        changed?(selected,options)
    }
}
