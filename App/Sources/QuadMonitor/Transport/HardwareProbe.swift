import Foundation

struct HardwareDeviceInfo: Sendable {
    let vendorID: UInt16
    let productID: UInt16
    let locationIDHex: String?
    let productName: String?
    let vendorName: String?
}

enum HardwareProbeError: Error {
    case probeFailed
}

struct HardwareProbe {
    static func findDevices(vendorID: UInt16, productID: UInt16) throws -> [HardwareDeviceInfo] {
        let output = try runCommand(
            "/usr/sbin/ioreg",
            ["-p", "IOService", "-n", "USB DISP", "-r", "-l", "-w", "0"]
        )

        let vidDec = String(vendorID)
        let pidDec = String(productID)

        let sections = output
            .components(separatedBy: "+-o USB DISP@")
            .dropFirst()
            .map { "+-o USB DISP@" + $0 }

        var seen = Set<String>()
        var devices = [HardwareDeviceInfo]()

        for section in sections {
            guard section.contains("\"idVendor\" = \(vidDec)") &&
                    section.contains("\"idProduct\" = \(pidDec)") else {
                continue
            }

            let location = firstCapture(section, pattern: #"\"locationID\" = ([0-9]+)"#)
                .flatMap { Int($0) }
                .map { String(format: "0x%X", $0) } ?? "unknown"
            let productName = firstCapture(section, pattern: #"\"USB Product Name\" = \"([^\"]+)\""#)
            let vendorName = firstCapture(section, pattern: #"\"USB Vendor Name\" = \"([^\"]+)\""#)

            guard !seen.contains(location) else { continue }
            seen.insert(location)

            devices.append(
                HardwareDeviceInfo(
                    vendorID: vendorID,
                    productID: productID,
                    locationIDHex: location,
                    productName: productName,
                    vendorName: vendorName
                )
            )
        }

        return devices
    }

    static func findExclusiveOwners(vendorID: UInt16, productID: UInt16) throws -> [String] {
        let output = try runCommand(
            "/usr/sbin/ioreg",
            ["-p", "IOService", "-n", "DISP@0", "-r", "-l", "-w", "0"]
        )

        let vidDec = String(vendorID)
        let pidDec = String(productID)
        let sections = output
            .components(separatedBy: "+-o DISP@0")
            .dropFirst()
            .map { "+-o DISP@0" + $0 }

        var owners = Set<String>()
        for section in sections {
            guard section.contains("\"idVendor\" = \(vidDec)") &&
                    section.contains("\"idProduct\" = \(pidDec)") else {
                continue
            }

            if let owner = firstCapture(section, pattern: #"\"UsbExclusiveOwner\" = \"([^\"]+)\""#) {
                owners.insert(owner)
            }
        }

        return owners.sorted()
    }

    private static func runCommand(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments

        let outPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = Pipe()

        try process.run()
        // Read stdout before waitUntilExit to avoid pipe backpressure deadlock
        // on large ioreg outputs.
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw HardwareProbeError.probeFailed
        }

        return String(decoding: data, as: UTF8.self)
    }

    private static func firstCapture(_ text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(location: 0, length: text.utf16.count)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

}
