import Foundation

public struct EncodingSnapshot: Sendable {
    public let pixels: Data
    public let stride: Int
    public let generation: Int
    public let createdAt: Double
    public init(pixels: Data, stride: Int, generation: Int, createdAt: Double) {
        self.pixels=pixels; self.stride=stride; self.generation=generation; self.createdAt=createdAt
    }
}

public struct PipelinedPreparation: Sendable {
    public let encoder: DeltaEncoder
    public let frame: PreparedFrame?
    public let snapshot: EncodingSnapshot
}

/// One bounded, speculative CPU job. No I/O or authoritative history is owned
/// here. All shared mutable state is locked; snapshots/encoder state are values.
/// A result needs both the real preceding ACK and an exact latest-generation
/// match. A late job never blocks the caller and cannot queue another job.
public final class FramePreparationPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "verified.prepare", qos: .userInitiated)
    private var busy = false
    private var ticket: UUID?
    private var accepted = false
    private var result: PipelinedPreparation?
    public init() {}

    @discardableResult
    public func start(encoder: DeltaEncoder, completing frame: PreparedFrame,
                      snapshot: @escaping @Sendable () throws -> EncodingSnapshot?) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !busy, ticket == nil else { return false }
        // This is a private prediction. The caller's pending frame and histories
        // remain untouched until the actual parent ACK arrives.
        var predicted = encoder
        try predicted.complete(frame, transferred: frame.data.count, succeeded: true)
        let initial = predicted
        busy=true; ticket=frame.id; accepted=false
        queue.async { [self] in
            var next = initial
            var prepared: PipelinedPreparation?
            do {
                if let snapshot = try snapshot() {
                    let frame = try next.prepare(bgra:snapshot.pixels,stride:snapshot.stride,generation:snapshot.generation)
                    prepared=PipelinedPreparation(encoder:next,frame:frame,snapshot:snapshot)
                }
            } catch {
                // The normal path retries preparation from the latest snapshot,
                // surfacing capture/encoding errors there. No USB retry occurs.
            }
            lock.lock(); busy=false
            if ticket == frame.id { result=prepared }
            lock.unlock()
        }
        return true
    }

    public func acknowledge(_ frame: PreparedFrame, transferred: Int, succeeded: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard ticket == frame.id else { return }
        accepted=succeeded && transferred == frame.data.count
        if !accepted { ticket=nil; result=nil }
    }

    /// Consumes or discards the slot without waiting. A busy discarded job keeps
    /// its worker reservation until it finishes, so work cannot accumulate.
    public func take(generation: Int) -> PipelinedPreparation? {
        lock.lock(); defer { lock.unlock() }
        defer { ticket=nil; result=nil; accepted=false }
        guard accepted, let result, result.snapshot.generation == generation else { return nil }
        return result
    }
    public func discard() {
        lock.lock(); ticket=nil; result=nil; accepted=false; lock.unlock()
    }
    public var isPreparing: Bool {
        lock.lock(); defer { lock.unlock() }; return busy
    }
}
