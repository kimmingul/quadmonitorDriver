import Foundation
#if os(macOS)
import Darwin
#endif

@main
struct QuadMonitor {
    static func main() async {
        #if os(macOS)
        signal(SIGPIPE, SIG_IGN)
        setbuf(stdout, nil)
        setbuf(stderr, nil)
        #endif

        if CommandLine.arguments.contains("--desktop-app") || Bundle.main.bundleIdentifier == "com.quadmonitor.desktop" {
            do {
                var defaults: [String:String]=[:]
                if let url=Bundle.main.url(forResource:"desktop-config",withExtension:"json") {
                    defaults=try JSONDecoder().decode([String:String].self,from:Data(contentsOf:url))
                }
                if defaults["packaged"] == "true" {
                    let support=try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,
                                                            appropriateFor:nil,create:true)
                    defaults=DesktopAppConfiguration.bundledDefaults(bundle:Bundle.main.bundleURL,support:support)
                }
                let desktop=try DesktopAppConfiguration.parse(CommandLine.arguments,defaults:defaults)
                DesktopApp.run(desktop)
            } catch {
                FileHandle.standardError.write(Data("Desktop app configuration failed: \(error)\n".utf8))
                exit(2)
            }
            return
        }

        let logger = Logger(subsystem: "com.racer.optimized", category: "main")
        let config = DriverConfiguration.fromProcessArguments(CommandLine.arguments)
        let traceRecorder = ProtocolTraceRecorder(logger: logger)
        await traceRecorder.announcePathIfEnabled()

        logger.info("Starting driver core (mode: \(config.mode.rawValue))")
        PermissionAdvisor.preflight(config: config, logger: logger)

        let transport: USBTransport
        switch config.mode {
        case .dryRun:
            transport = MockUSBTransport(latencyMs: config.mockTransportLatencyMs)
        case .hardware:
            if config.useIOUSBHost {
                transport = IOUSBHostTransport(
                    logger: logger,
                    vendorID: config.vendorID,
                    productID: config.productID
                )
                logger.info("Using IOUSBHost framework USB transport")
            } else if config.useIOKit {
                transport = IOKitUSBTransport(
                    logger: logger,
                    vendorID: config.vendorID,
                    productID: config.productID
                )
                logger.info("Using legacy IOKit/IOUSBLib USB transport")
            } else {
                transport = LibUSBTransport(
                    logger: logger,
                    vendorID: config.vendorID,
                    productID: config.productID
                )
                logger.info("Using libusb USB transport")
            }
        }

        let usbManager = USBManager(transport: transport, logger: logger, traceRecorder: traceRecorder)
        let displayManager = DisplayManager(logger: logger)
        let powerManager = PowerManager(logger: logger)
        let videoPipeline = VideoPipeline(logger: logger)
        let runtimeMetrics = RuntimeMetrics()

        let orchestrator = DriverOrchestrator(
            config: config,
            usbManager: usbManager,
            displayManager: displayManager,
            powerManager: powerManager,
            videoPipeline: videoPipeline,
            logger: logger,
            runtimeMetrics: runtimeMetrics
        )

        await orchestrator.start()
    }
}
