import Foundation

/// Coalescing notification: no queue of stale frames or accumulated wake tokens.
public final class FrameArrival: @unchecked Sendable {
    private let condition=NSCondition()
    private var generation=0
    public init() {}
    public func publish(_ value: Int) {
        condition.lock(); generation=max(generation,value); condition.broadcast(); condition.unlock()
    }
    @discardableResult
    public func wait(after value: Int, timeout: Double) -> Bool {
        condition.lock();defer { condition.unlock() }
        let deadline=Date(timeIntervalSinceNow:max(0,timeout))
        while generation<=value {
            if !condition.wait(until:deadline) { break }
        }
        return generation>value
    }
}
