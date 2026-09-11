import Foundation

/// Monotonic start deadlines. Slow frames must not build a catch-up queue.
public struct FramePacer {
    private let interval: Double
    private var nextStart: Double

    public init(fps: Int, startedAt: Double) {
        precondition(fps > 0)
        interval = 1 / Double(fps)
        nextStart = startedAt + interval
    }

    public mutating func deadline(completedAt: Double) -> Double {
        if nextStart <= completedAt {
            nextStart = completedAt + interval
            return completedAt
        }
        let deadline = nextStart
        nextStart += interval
        return deadline
    }
}

/// One serial capture worker, one outstanding wait. A one-shot strict timer
/// avoids accumulated wake tokens when encoding or USB takes multiple periods.
/// This sleeps the worker; it never spins or changes system-wide timer policy.
public final class FrameWaiter {
    private let timer: DispatchSourceTimer
    private let wake = DispatchSemaphore(value: 0)

    public init() {
        timer = DispatchSource.makeTimerSource(flags: .strict,
            queue: DispatchQueue(label: "verified.frame-deadline", qos: .userInteractive))
        let wake = self.wake
        timer.setEventHandler { wake.signal() }
        timer.schedule(deadline: .distantFuture)
        timer.resume()
    }

    public func wait(untilUptime deadline: Double) {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return }
            timer.schedule(deadline: .now() + remaining, leeway: .nanoseconds(0))
            wake.wait()
            // Dispatch permits an early firing; re-arm instead of returning early.
        }
    }

    deinit { timer.cancel() }
}
