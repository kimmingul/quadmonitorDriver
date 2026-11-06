import AppKit
import ApplicationServices
import CoreGraphics

/// Global display geometry for the Dock guard (CoreGraphics coordinates: origin
/// top-left, y grows downward). macOS moves a bottom Dock to whichever display's
/// free bottom edge the cursor presses, so every such edge except the main
/// display's is guarded, corners included.
struct DockGuardLayout: Equatable, Sendable {
    /// Measured on macOS with virtual panels: dropping mouse-moved events in
    /// this band kept the Dock in place, while passing even one edge event let
    /// the Dock follow the cursor.
    static let zone: CGFloat = 3
    let main: CGRect
    let others: [CGRect]

    private func covered(_ point: CGPoint) -> Bool {
        main.contains(point) || others.contains { $0.contains(point) }
    }

    /// True when `point` presses a bottom edge of a non-main display that has
    /// no display below it, i.e. where macOS would move the Dock.
    func blocks(_ point: CGPoint) -> Bool {
        guard !main.contains(point), let display=others.first(where:{ $0.contains(point) }),
              point.y >= display.maxY-Self.zone else { return false }
        return !covered(CGPoint(x:point.x,y:display.maxY+0.5))
    }

    /// True when the Dock's frame lies on a non-main display.
    func dockIsAway(_ dock: CGRect) -> Bool {
        let center=CGPoint(x:dock.midX,y:dock.midY)
        return !main.contains(center) && others.contains { $0.contains(center) }
    }

    /// A point on a free part of the main display's bottom edge, used to call
    /// the Dock back; nil when another display covers that edge.
    var mainEdgePoint: CGPoint? {
        [0.5,0.25,0.75].map { CGPoint(x:main.minX+main.width*$0,y:main.maxY-1) }
            .first { !covered(CGPoint(x:$0.x,y:main.maxY+0.5)) }
    }
}

/// Distinguishes this app's relocation events from real mouse input.
private let dockPinMarker: Int64 = 0x5155_4144

private func dockPinCallback(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent,
                             _ info: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    // `info` is the app-lifetime DockPin; pass its address, dereference on the main actor.
    guard let owner=info.map(UInt.init(bitPattern:)) else { return Unmanaged.passUnretained(event) }
    let location=event.location
    let synthetic=event.getIntegerValueField(.eventSourceUserData)==dockPinMarker
    // The tap's run-loop source is installed on the main run loop.
    let drop=MainActor.assumeIsolated {
        Unmanaged<DockPin>.fromOpaque(UnsafeRawPointer(bitPattern:owner)!).takeUnretainedValue()
            .shouldDrop(type,location,synthetic)
    }
    return drop ? nil : Unmanaged.passUnretained(event)
}

/// Keeps a bottom Dock on the system main display by withholding mouse-moved
/// events that press free bottom edges of other displays. Requires the
/// Accessibility permission for an event tap that can drop events.
@MainActor
final class DockPin {
    enum State: Equatable { case off, needsPermission, unsupportedSide, active }
    private(set) var state=State.off
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var layout: DockGuardLayout?
    private var prompted=false
    private var relocating=false
    private var lastRelocation = -Double.infinity

    /// Call periodically; display layout and Dock orientation are re-read each time.
    func update(enabled: Bool) {
        guard enabled else { remove();prompted=false;state = .off;return }
        if tap == nil, !install() { state = .needsPermission;return }
        guard Self.dockAtBottom() else { layout=nil;state = .unsupportedSide;return }
        let current=Self.currentLayout()
        let changed=current != layout || state != .active
        layout=current;state = .active
        if changed { Task { await relocateIfAway() } }
    }

    fileprivate func shouldDrop(_ type: CGEventType, _ location: CGPoint, _ synthetic: Bool) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap:tap,enable:true) }
            return false
        }
        if relocating { return !synthetic }
        return layout?.blocks(location) == true
    }

    private func install() -> Bool {
        guard AXIsProcessTrusted() else {
            if !prompted {
                prompted=true
                _=AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt":true] as CFDictionary)
            }
            return false
        }
        guard let tap=CGEvent.tapCreate(tap:.cgSessionEventTap,place:.headInsertEventTap,options:.defaultTap,
                                        eventsOfInterest:CGEventMask(1 << CGEventType.mouseMoved.rawValue),
                                        callback:dockPinCallback,userInfo:Unmanaged.passUnretained(self).toOpaque())
        else { return false }
        let source=CFMachPortCreateRunLoopSource(kCFAllocatorDefault,tap,0)
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        CGEvent.tapEnable(tap:tap,enable:true)
        self.tap=tap;self.source=source
        return true
    }

    private func remove() {
        if let tap { CGEvent.tapEnable(tap:tap,enable:false);CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        tap=nil;source=nil;layout=nil
    }

    /// Moves a Dock that is already on another display back to the main display
    /// by pressing the main display's bottom edge, then restores the cursor.
    private func relocateIfAway() async {
        let now=ProcessInfo.processInfo.systemUptime
        guard !relocating, now-lastRelocation>2, NSEvent.pressedMouseButtons==0, let layout,
              let dock=Self.dockFrame(), layout.dockIsAway(dock), let edge=layout.mainEdgePoint else { return }
        relocating=true;lastRelocation=now
        defer { relocating=false }
        let original=CGEvent(source:nil)?.location
        let events=CGEventSource(stateID:.hidSystemState)
        func press(_ point: CGPoint, deltaY: Int64) {
            CGWarpMouseCursorPosition(point)
            guard let move=CGEvent(mouseEventSource:events,mouseType:.mouseMoved,mouseCursorPosition:point,mouseButton:.left) else { return }
            move.setIntegerValueField(.eventSourceUserData,value:dockPinMarker)
            move.setIntegerValueField(.mouseEventDeltaY,value:deltaY)
            move.post(tap:.cghidEventTap)
        }
        for step in 0..<8 {
            press(CGPoint(x:edge.x,y:edge.y-49+CGFloat(step)*7),deltaY:7)
            try? await Task.sleep(for:.milliseconds(15))
        }
        // The Dock needs a sustained press, longer right after a previous move.
        for step in 0..<60 {
            guard state == .active else { break }
            press(edge,deltaY:4)
            try? await Task.sleep(for:.milliseconds(25))
            if step%4==3, let dock=Self.dockFrame(), !layout.dockIsAway(dock) { break }
        }
        if let original { CGWarpMouseCursorPosition(original) }
    }

    private static func dockAtBottom() -> Bool {
        let domain="com.apple.dock" as CFString
        _=CFPreferencesAppSynchronize(domain)
        let side=CFPreferencesCopyAppValue("orientation" as CFString,domain) as? String
        return side == nil || side == "bottom"
    }

    private static func currentLayout() -> DockGuardLayout {
        var count: UInt32=0
        _=CGGetActiveDisplayList(0,nil,&count)
        var ids=[CGDirectDisplayID](repeating:0,count:Int(count))
        _=CGGetActiveDisplayList(count,&ids,&count)
        let main=CGDisplayBounds(CGMainDisplayID())
        // Mirrors of the main display share its bounds and are not separate edges.
        let others=ids.prefix(Int(count)).map(CGDisplayBounds).filter { $0 != main }
            .sorted { ($0.minX,$0.minY) < ($1.minX,$1.minY) }
        return DockGuardLayout(main:main,others:others)
    }

    /// Frame of the Dock's tile list in global coordinates, via Accessibility.
    private static func dockFrame() -> CGRect? {
        guard let dock=NSRunningApplication.runningApplications(withBundleIdentifier:"com.apple.dock").first else { return nil }
        let app=AXUIElementCreateApplication(dock.processIdentifier)
        var children: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app,kAXChildrenAttribute as CFString,&children) == .success,
              let list=(children as? [AXUIElement])?.first else { return nil }
        var position: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(list,kAXPositionAttribute as CFString,&position) == .success,
              AXUIElementCopyAttributeValue(list,kAXSizeAttribute as CFString,&size) == .success,
              let position,let size,CFGetTypeID(position)==AXValueGetTypeID(),CFGetTypeID(size)==AXValueGetTypeID()
        else { return nil }
        var origin=CGPoint.zero, extent=CGSize.zero
        guard AXValueGetValue(position as! AXValue,.cgPoint,&origin),
              AXValueGetValue(size as! AXValue,.cgSize,&extent) else { return nil }
        return CGRect(origin:origin,size:extent)
    }
}
