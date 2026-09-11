import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

enum PermissionAdvisor {
    static func preflight(config: DriverConfiguration, logger: Logger) {
        guard config.mode == .hardware else { return }

        #if canImport(CoreGraphics)
        if !CGPreflightScreenCaptureAccess() {
            logger.warning("Screen Recording permission is not granted. Open System Settings > Privacy & Security > Screen Recording and allow Terminal/VS Code + this app.")
        }
        #endif

        logger.info("If USB claim fails with access denied, run with elevated privileges and ensure no other app owns USB DISP interface.")
    }

    static func reportStartupFailure(
        _ error: Error,
        config: DriverConfiguration,
        logger: Logger
    ) {
        let message = error.localizedDescription

        if message.contains("access denied while claiming USB interface") {
            logger.error("Permission required: USB interface access is denied by macOS.")
            logger.info("Action 1: Quit original UsbDisplay app if running.")
            logger.info("Action 2: Grant Screen Recording permission to Terminal/VS Code and this app.")
            logger.info("Action 3: Re-run with sudo: sudo swift run QuadMonitor --hardware --monitors=\(config.monitorCount) --fps=\(config.targetFPS) --vid=0x\(String(config.vendorID, radix: 16, uppercase: true)) --pid=0x\(String(config.productID, radix: 16, uppercase: true))")

            if let owners = try? HardwareProbe.findExclusiveOwners(vendorID: config.vendorID, productID: config.productID), !owners.isEmpty {
                logger.warning("USB DISP exclusive owner(s): \(owners.joined(separator: ", "))")
            }
        } else if message.contains("no writable endpoint found") {
            logger.error("Protocol/endpoint issue detected: writable endpoint not resolved.")
            logger.info("Action: ensure no owner process is attached and run probe mode again after reconnecting the dock.")
        }
    }
}
