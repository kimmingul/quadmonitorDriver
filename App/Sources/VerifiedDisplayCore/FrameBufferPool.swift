import Foundation

/// Only unused storage is cached. Data leases keep buffers alive across ACKs and
/// encoder copies; the last Data reference returns storage under the lock.
final class FrameBufferPool: @unchecked Sendable {
    let capacity: Int
    private let lock = NSLock()
    private var free: [UnsafeMutableRawPointer] = []
    init(capacity: Int) { self.capacity = capacity }
    deinit { for pointer in free { pointer.deallocate() } }

    func acquire() -> (pointer: UnsafeMutableRawPointer, reused: Bool) {
        lock.lock(); let pointer = free.popLast(); lock.unlock()
        return (pointer ?? .allocate(byteCount: capacity, alignment: 16), pointer != nil)
    }
    func release(_ pointer: UnsafeMutableRawPointer) {
        lock.lock()
        if free.count < 2 { free.append(pointer); lock.unlock() }
        else { lock.unlock(); pointer.deallocate() }
    }
    func lease(_ pointer: UnsafeMutableRawPointer, count: Int) -> Data {
        Data(bytesNoCopy: pointer, count: count, deallocator: .custom { [self] pointer, _ in
            release(pointer)
        })
    }
}
