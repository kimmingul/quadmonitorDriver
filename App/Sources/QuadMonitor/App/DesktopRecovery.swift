/// Run intent outlives one coordinator, but never a manual Stop or Quit.
struct DesktopRecovery {
    private(set) var requested = false
    private(set) var sleeping = false
    private(set) var waiting = false

    mutating func startRequested() { requested = true; waiting = false }
    mutating func sessionStarted() { waiting = false }
    mutating func stopRequested() { requested = false; waiting = false }
    mutating func willSleep() { sleeping = true; if requested { waiting = true } }
    mutating func didWake() { sleeping = false }
    mutating func sessionEnded(disconnected: Bool) {
        guard requested else { return }
        if disconnected || waiting { waiting = true }
        else { stopRequested() }
    }
    func shouldResume(devicesReady: Bool) -> Bool {
        requested && waiting && !sleeping && devicesReady
    }
}
