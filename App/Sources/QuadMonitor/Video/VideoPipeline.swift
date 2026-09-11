import Foundation

actor VideoPipeline {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func encodeSyntheticFrame(displayIndex: UInt8, frameNumber: UInt64) -> DeviceFrame {
        // Placeholder payload that keeps transport and scheduling logic testable.
        let payload = "display=\(displayIndex);frame=\(frameNumber)".data(using: .utf8) ?? Data()
        return DeviceFrame(
            displayIndex: displayIndex,
            timestampMs: UInt64(Date().timeIntervalSince1970 * 1_000),
            encodedBytes: payload
        )
    }

    func logPipelineReady() {
        logger.info("Video pipeline ready (synthetic encoder mode)")
    }
}
