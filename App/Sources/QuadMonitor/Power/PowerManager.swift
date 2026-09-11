import Foundation

actor PowerManager {
    private let logger: Logger

    init(logger: Logger) {
        self.logger = logger
    }

    func recommendedTargetFPS(baseFPS: Int) -> Int {
        #if os(macOS)
        if ProcessInfo.processInfo.isLowPowerModeEnabled {
            let adjusted = max(30, baseFPS / 2)
            logger.warning("Low power mode enabled, reducing target FPS to \(adjusted)")
            return adjusted
        }
        #endif

        return baseFPS
    }
}
