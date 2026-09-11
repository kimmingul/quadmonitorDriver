import Foundation
import CFrameEncoder

public enum FrameError: Error { case invalidPixels, encodingFailed, pendingTransfer, staleTransfer }

public struct PreparationMetrics: Sendable {
    public var copySeconds = 0.0
    public var compareSeconds = 0.0
    public var encodeSeconds = 0.0
    public var copiedBytes = 0
    public var outputBufferReused = false
    public var encoderWorkers = 0
    public var reusedSettledGeneration = false
}

public struct PreparedFrame: Sendable {
    public let id: UUID
    public let data: Data
    public let tiles: [Int]
}

/// Confine to one serial worker. Only full USB completion commits a history slot.
public struct DeltaEncoder: Sendable {
    public let width: Int
    public let height: Int
    private let options: PerformanceOptions
    private let metal: MetalTileDiffer?
    private let buffers: FrameBufferPool?
    private var histories: [Data?] = [nil, nil]
    private var slot = 0
    private var pending: (id: UUID, pixels: Data, byteCount: Int)?
    private var settledGeneration: Int?
    public private(set) var lastPreparation = PreparationMetrics()
    public init(width: Int, height: Int, options: PerformanceOptions = PerformanceOptions()) throws {
        guard options.isValid, options.workers > 0 else { throw FrameError.invalidPixels }
        guard width > 0, height > 0, width <= 65536, height <= 65536,
              racer_frame_capacity(UInt32(width), UInt32(height)) > 0 else { throw FrameError.invalidPixels }
        self.width = width; self.height = height; self.options=options
        self.buffers = options.reuseBuffers ? FrameBufferPool(capacity: racer_frame_capacity(UInt32(width), UInt32(height))) : nil
        self.metal = options.damage == .metal ? try MetalTileDiffer(width:width,height:height) : nil
    }
    /// A generation must uniquely identify immutable pixels within this encoder's
    /// lifetime. Omit it when the caller cannot guarantee that identity.
    public mutating func prepare(bgra: Data, stride: Int, generation: Int? = nil) throws -> PreparedFrame? {
        lastPreparation = PreparationMetrics()
        guard pending == nil else { throw FrameError.pendingTransfer }
        let rowBytes = width * 4
        guard stride >= rowBytes, stride <= Int.max / height,
              bgra.count >= stride * height else { throw FrameError.invalidPixels }
        if let generation, generation == settledGeneration {
            lastPreparation.reusedSettledGeneration = true
            return nil
        }
        settledGeneration = nil
        // Packed Data can share immutable storage with both histories. A caller
        // mutation uses Data's copy-on-write; padding still needs canonical rows.
        let copyStarted = ProcessInfo.processInfo.systemUptime
        var pixels: Data
        if stride == rowBytes && bgra.count == rowBytes * height {
            pixels = bgra
        } else {
            pixels = Data(count: rowBytes * height)
            pixels.withUnsafeMutableBytes { dst in
                bgra.withUnsafeBytes { src in
                    for row in 0..<height {
                        memcpy(dst.baseAddress! + row*rowBytes, src.baseAddress! + row*stride, rowBytes)
                    }
                }
            }
            lastPreparation.copiedBytes = rowBytes*height
        }
        lastPreparation.copySeconds = ProcessInfo.processInfo.systemUptime-copyStarted
        let compareStarted = ProcessInfo.processInfo.systemUptime
        let tileCount = (width/32) * (height/8)
        var mask = [UInt8](repeating: 0, count: tileCount)
        if let metal, let first=histories[0], let second=histories[1] {
            mask=try metal.changes(current:pixels,first:first,second:second)
        } else {
        for history in histories {
            guard let history else { mask = [UInt8](repeating: 1, count: tileCount); break }
            let result = pixels.withUnsafeBytes { current in
                history.withUnsafeBytes { previous in
                    mask.withUnsafeMutableBufferPointer { selection in
                        racer_mark_changed_tiles(current.bindMemory(to: UInt8.self).baseAddress,
                            previous.bindMemory(to: UInt8.self).baseAddress, pixels.count,
                            UInt32(width), UInt32(height), selection.baseAddress, selection.count)
                    }
                }
            }
            guard result == 0 else { throw FrameError.invalidPixels }
        }
        }
        if options.compression == .full && mask.contains(where:{$0 != 0}) { mask=Array(repeating:1,count:tileCount) }
        let tiles = mask.indices.filter { mask[$0] != 0 }
        lastPreparation.compareSeconds = ProcessInfo.processInfo.systemUptime-compareStarted
        guard !tiles.isEmpty else {
            // Only now are BOTH histories settled. The first two keyframes and
            // both copies of a changed frame must pass through exact USB ACKs.
            settledGeneration = generation
            return nil
        }
        let encodeStarted = ProcessInfo.processInfo.systemUptime
        let workers = options.workers(forChangedTiles: tiles.count)
        lastPreparation.encoderWorkers = workers
        let capacity = racer_frame_capacity(UInt32(width), UInt32(height))
        func encode(_ pointer: UnsafeMutablePointer<UInt8>?, _ count: Int) -> Int {
            pixels.withUnsafeBytes { src in
                mask.withUnsafeBufferPointer { selection in
                    racer_encode_bgra_workers(src.bindMemory(to: UInt8.self).baseAddress, pixels.count,
                        UInt32(width), UInt32(height), rowBytes, selection.baseAddress, mask.count,
                        pointer, count, UInt32(workers))
                }
            }
        }
        var data: Data
        let length: Int
        if let buffers {
            let storage = buffers.acquire()
            length = encode(storage.pointer.assumingMemoryBound(to: UInt8.self), capacity)
            guard length > 0 else { buffers.release(storage.pointer); throw FrameError.encodingFailed }
            data = buffers.lease(storage.pointer, count: length)
            lastPreparation.outputBufferReused = storage.reused
        } else {
            data = Data(count: capacity)
            length = data.withUnsafeMutableBytes { out in encode(out.bindMemory(to: UInt8.self).baseAddress, out.count) }
            guard length > 0 else { throw FrameError.encodingFailed }
            data.count = length
        }
        lastPreparation.encodeSeconds = ProcessInfo.processInfo.systemUptime-encodeStarted
        let id = UUID()
        pending = (id, pixels, length)
        return PreparedFrame(id: id, data: data, tiles: tiles)
    }

    public mutating func complete(_ frame: PreparedFrame, transferred: Int, succeeded: Bool) throws {
        guard let pending, pending.id == frame.id else { throw FrameError.staleTransfer }
        guard succeeded && transferred == pending.byteCount else { invalidate(); return }
        histories[slot] = pending.pixels
        slot ^= 1
        self.pending = nil
    }

    public mutating func invalidate() {
        histories = [nil, nil]; slot = 0; pending = nil; settledGeneration = nil
    }
}
