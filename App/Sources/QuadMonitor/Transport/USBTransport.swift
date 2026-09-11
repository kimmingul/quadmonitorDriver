import Foundation

protocol USBTransport: Sendable {
    func connect() async throws
    func write(_ bytes: Data) async throws
    func read(maxBytes: Int) async throws -> Data
    func disconnect() async

    /// Number of independently addressable USB units currently opened.
    func deviceCount() async -> Int

    /// Send a raw payload to a single device by index. Used to drive each
    /// USB DISP unit independently (instead of broadcasting to all of them
    /// the way `write(_:)` does for shared control packets).
    func writeRaw(deviceIndex: Int, bytes: Data) async throws

    /// Send a vendor OUT control transfer (bmRT=0x41) to a single device.
    /// Used for protocol experiments (SetPower, frame-start probes, etc.).
    func vendorOut(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, payload: Data) async throws -> Bool

    /// Clear a halted bulk endpoint to restore it to a writable state.
    func clearHalt(deviceIndex: Int) async throws

    /// Send a vendor IN control transfer (bmRT=0xC1) and return the data.
    func vendorIn(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, wLength: UInt16) async throws -> Data?
}

enum USBTransportError: Error {
    case disconnected
}

actor MockUSBTransport: USBTransport {
    private let latencyMs: UInt64
    private var connected = false
    private var inbox = [Data]()

    init(latencyMs: UInt64) {
        self.latencyMs = latencyMs
    }

    func connect() async throws {
        try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
        connected = true
    }

    func write(_ bytes: Data) async throws {
        guard connected else { throw USBTransportError.disconnected }
        try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
        inbox.append(bytes)
    }

    func read(maxBytes: Int) async throws -> Data {
        guard connected else { throw USBTransportError.disconnected }
        try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
        guard !inbox.isEmpty else { return Data([ProtocolCommand.heartbeat.rawValue, 0, 0]) }

        let next = inbox.removeFirst()
        return next.prefix(maxBytes)
    }

    func disconnect() async {
        connected = false
        inbox.removeAll(keepingCapacity: false)
    }

    func deviceCount() async -> Int { connected ? 1 : 0 }

    func writeRaw(deviceIndex: Int, bytes: Data) async throws {
        guard connected else { throw USBTransportError.disconnected }
        try await Task.sleep(nanoseconds: latencyMs * 1_000_000)
        inbox.append(bytes)
    }

    func vendorOut(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, payload: Data) async throws -> Bool {
        guard connected else { throw USBTransportError.disconnected }
        return true
    }

    func clearHalt(deviceIndex: Int) async throws {
        guard connected else { throw USBTransportError.disconnected }
    }

    func vendorIn(deviceIndex: Int, bRequest: UInt8, wValue: UInt16, wLength: UInt16) async throws -> Data? {
        guard connected else { throw USBTransportError.disconnected }
        return Data()
    }
}
