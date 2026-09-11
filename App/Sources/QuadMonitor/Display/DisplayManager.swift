import Foundation

struct DisplayTarget: Sendable {
    let index: UInt8
    let mode: DisplayMode
}

actor DisplayManager {
    private let logger: Logger
    private(set) var targets: [DisplayTarget] = []

    init(logger: Logger) {
        self.logger = logger
    }

    func configureDefaultDisplays(count: Int, targetFPS: Int) {
        targets = (0..<count).map { idx in
            DisplayTarget(
                index: UInt8(idx),
                mode: DisplayMode(width: 2560, height: 1440, refreshRate: UInt8(targetFPS))
            )
        }

        logger.info("Configured \(targets.count) virtual display targets")
    }
}
