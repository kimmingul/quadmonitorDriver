import Foundation
import Testing
@testable import QuadMonitor

@Test func packetSerializationIncludesHeader() async throws {
    let packet = CommandPacket(command: .initialize, payload: Data([0xAA, 0xBB]))
    let bytes = packet.serialize()

    #expect(bytes.count == 5)
    #expect(bytes[0] == ProtocolCommand.initialize.rawValue)
    #expect(bytes[1] == 2)
    #expect(bytes[2] == 0)
    #expect(bytes[3] == 0xAA)
    #expect(bytes[4] == 0xBB)
}

@Test func displayPayloadEncodingIsLittleEndian() async throws {
    let mode = DisplayMode(width: 2560, height: 1440, refreshRate: 60)
    let payload = mode.toPayload(displayIndex: 2)

    #expect(payload.count == 6)
    #expect(payload[0] == 2)
    #expect(payload[1] == 0x00)
    #expect(payload[2] == 0x0A)
    #expect(payload[3] == 0xA0)
    #expect(payload[4] == 0x05)
    #expect(payload[5] == 60)
}

@Test func mockTransportRoundTrip() async throws {
    let transport = MockUSBTransport(latencyMs: 0)
    let logger = Logger(subsystem: "test", category: "usb")
    let recorder = ProtocolTraceRecorder(logger: logger, enabled: false)
    let manager = USBManager(transport: transport, logger: logger, traceRecorder: recorder)

    try await manager.connect()
    try await manager.initializeDevice()
    try await manager.heartbeat()

    // No throw means end-to-end transport path is valid for bootstrap mode.
    #expect(Bool(true))
}

@Test func configParsesHardwareArguments() async throws {
    let args = [
        "QuadMonitor",
        "--hardware",
        "--monitors=4",
        "--fps=75",
        "--vid=0x34C7",
        "--pid=0x2114"
    ]

    let config = DriverConfiguration.fromProcessArguments(args)

    #expect(config.mode == .hardware)
    #expect(config.monitorCount == 4)
    #expect(config.targetFPS == 75)
    #expect(config.vendorID == 0x34C7)
    #expect(config.productID == 0x2114)
}
