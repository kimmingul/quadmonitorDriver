import Foundation
import OSLog

struct Logger {
    private let osLogger: os.Logger

    init(subsystem: String, category: String) {
        osLogger = os.Logger(subsystem: subsystem, category: category)
    }

    func info(_ message: String) {
        osLogger.info("\(message, privacy: .public)")
        print("[INFO] \(message)")
        fflush(stdout)
    }

    func warning(_ message: String) {
        osLogger.warning("\(message, privacy: .public)")
        print("[WARN] \(message)")
        fflush(stdout)
    }

    func error(_ message: String) {
        osLogger.error("\(message, privacy: .public)")
        fputs("[ERROR] \(message)\n", stderr)
        fflush(stderr)
    }
}
