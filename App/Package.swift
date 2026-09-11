// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "QuadMonitor",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(name: "CFrameEncoder", publicHeadersPath: "include"),
        .target(name: "VerifiedDisplayCore", dependencies: ["CFrameEncoder"]),
        .testTarget(name: "VerifiedDisplayCoreTests", dependencies: ["VerifiedDisplayCore"]),
        .target(name: "VerifiedUSB", dependencies: ["CLibUSB", "CFrameEncoder", "VerifiedDisplayCore"]),
        .testTarget(name: "VerifiedUSBTests", dependencies: ["VerifiedUSB", "VerifiedDisplayCore"]),
        .executableTarget(name: "VerifiedCapture", dependencies: ["VerifiedDisplayCore", "VerifiedUSB"]),
        .executableTarget(name: "VerifiedSession", dependencies: ["VerifiedDisplayCore", "VerifiedUSB"]),
        .testTarget(name: "VerifiedSessionTests", dependencies: ["VerifiedSession"]),
        .executableTarget(name: "VerifiedDesktopHost",
            cSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("AppKit"), .linkedFramework("CoreGraphics")]),
        .systemLibrary(
            name: "CLibUSB",
            pkgConfig: "libusb-1.0",
            providers: [
                .brew(["libusb"])
            ]
        ),
        .target(
            name: "CIOKitUSB",
            publicHeadersPath: "include",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .executableTarget(
            name: "QuadMonitor",
            dependencies: ["CLibUSB", "CIOKitUSB", "VerifiedDisplayCore"],
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("IOUSBHost"),
                .linkedFramework("Foundation"),
            ]
        ),
        .testTarget(
            name: "QuadMonitorTests",
            dependencies: ["QuadMonitor"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
