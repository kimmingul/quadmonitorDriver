import Foundation

enum ProtocolCommand: UInt8, Sendable {
    case initialize = 0x01
    case setDisplayMode = 0x10
    case startStream = 0x20
    case stopStream = 0x21
    case heartbeat = 0x30
}

struct DisplayMode: Sendable, Equatable {
    let width: UInt16
    let height: UInt16
    let refreshRate: UInt8
}

struct CommandPacket: Sendable, Equatable {
    let command: ProtocolCommand
    let payload: Data

    func serialize() -> Data {
        var data = Data([command.rawValue])
        data.append(UInt8(payload.count & 0xFF))
        data.append(UInt8((payload.count >> 8) & 0xFF))
        data.append(payload)
        return data
    }
}

struct DeviceFrame: Sendable, Equatable {
    let displayIndex: UInt8
    let timestampMs: UInt64
    let encodedBytes: Data
}

extension DisplayMode {
    func toPayload(displayIndex: UInt8) -> Data {
        var bytes = Data()
        bytes.append(displayIndex)
        bytes.append(UInt8(width & 0xFF))
        bytes.append(UInt8((width >> 8) & 0xFF))
        bytes.append(UInt8(height & 0xFF))
        bytes.append(UInt8((height >> 8) & 0xFF))
        bytes.append(refreshRate)
        return bytes
    }
}
