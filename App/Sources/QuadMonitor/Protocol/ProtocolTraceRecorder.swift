import Foundation

actor ProtocolTraceRecorder {
    private let logger: Logger
    private let fileURL: URL
    private let enabled: Bool

    init(logger: Logger, enabled: Bool = true) {
        self.logger = logger
        self.enabled = enabled
        self.fileURL = URL(fileURLWithPath: "/tmp/racerusb_protocol_trace.log")
    }

    func record(direction: String, packet: Data) {
        guard enabled else { return }

        let line = "\(isoNow()) \(direction) \(packet.hexString())\n"
        if let data = line.data(using: .utf8) {
            append(data)
        }
    }

    func announcePathIfEnabled() {
        guard enabled else { return }
        logger.info("Protocol trace enabled: \(fileURL.path)")
    }

    private func append(_ data: Data) {
        do {
            let handle: FileHandle
            if FileManager.default.fileExists(atPath: fileURL.path) {
                handle = try FileHandle(forWritingTo: fileURL)
                try handle.seekToEnd()
            } else {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
                handle = try FileHandle(forWritingTo: fileURL)
            }

            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            logger.warning("Failed to append protocol trace: \(error.localizedDescription)")
        }
    }

    private func isoNow() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }
}

private extension Data {
    func hexString() -> String {
        map { String(format: "%02X", $0) }.joined()
    }
}
