import Foundation

actor ProtocolProbe {
    private let usbManager: USBManager
    private let logger: Logger

    init(usbManager: USBManager, logger: Logger) {
        self.usbManager = usbManager
        self.logger = logger
    }

    func runCommandByteSweep(range: ClosedRange<UInt8>) async {
        logger.info("Protocol probe started: sweeping command bytes \(range.lowerBound)...\(range.upperBound)")

        var successCount = 0
        for cmd in range {
            let packet = Data([cmd, 0x00, 0x00])
            do {
                try await usbManager.sendRaw(packet)
                successCount += 1
                logger.info("Probe accepted cmd=\(String(format: "0x%02X", cmd))")
            } catch {
                logger.warning("Probe rejected cmd=\(String(format: "0x%02X", cmd)) error=\(error.localizedDescription)")
            }
        }

        logger.info("Protocol probe completed: accepted=\(successCount), total=\(range.count)")

        await runStringCommandProbe()
    }

    private func runStringCommandProbe() async {
        let commands = [
            "GetStatus",
            "GetEDID",
            "GetFeatures",
            "GetProductType",
            "ResetDevice"
        ]

        logger.info("Protocol probe stage 2: ASCII command probe")

        for command in commands {
            guard let payload = command.data(using: .ascii) else { continue }

            var packet = Data()
            packet.append(0x7E)
            packet.append(UInt8(payload.count & 0xFF))
            packet.append(UInt8((payload.count >> 8) & 0xFF))
            packet.append(payload)

            do {
                try await usbManager.sendRaw(packet)
                logger.info("ASCII probe accepted command=\(command)")
            } catch {
                logger.warning("ASCII probe rejected command=\(command) error=\(error.localizedDescription)")
            }
        }
    }
}
