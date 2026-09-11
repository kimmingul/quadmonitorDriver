import Foundation
#if canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif

/// Static JPEG frame generator used for Stage A end-to-end validation
/// of the bulk OUT pipe. The payload is a 1920×1200 RGBA test pattern
/// (color bars + display-index banner) compressed to JPEG via ImageIO.
///
/// Per `RacerUSB_Protocol_ReverseEngineered.md` §6, the device decodes
/// the JPEG bitstream using the DQT we uploaded over `bReq=0x83`, so we
/// surgically replace whatever DQT segments ImageIO emits with our own
/// 138-byte payload. That matches both interpretations of the protocol:
///   * if the firmware reads in-stream DQT, it sees the expected tables
///   * if the firmware ignores in-stream DQT, the payload is harmless
struct JPEGTestFrame {
    let width: Int = 1920
    let height: Int = 1200
    /// Reference DQT bytes that the device was unlocked with
    /// (luma table FF DB 00 43 00 ... + chroma table FF DB 00 43 01 ...).
    let dqtMarker: [UInt8]

    init(dqtMarker: [UInt8]) {
        self.dqtMarker = dqtMarker
    }

    func encode(displayIndex: Int) -> Data? {
        #if canImport(CoreGraphics) && canImport(ImageIO)
        guard let cgImage = renderTestPattern(displayIndex: displayIndex) else { return nil }
        guard let raw = jpegEncode(image: cgImage, quality: 0.85) else { return nil }
        return replaceDQTSegment(in: raw, with: Data(dqtMarker))
        #else
        return nil
        #endif
    }

    #if canImport(CoreGraphics) && canImport(ImageIO)
    private func renderTestPattern(displayIndex: Int) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: cs, bitmapInfo: info.rawValue
        ) else { return nil }

        // 8 vertical color bars
        let bars: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 1, 1), (1, 1, 0), (0, 1, 1), (0, 1, 0),
            (1, 0, 1), (1, 0, 0), (0, 0, 1), (0.1, 0.1, 0.1)
        ]
        let barW = CGFloat(width) / CGFloat(bars.count)
        for (i, c) in bars.enumerated() {
            ctx.setFillColor(red: c.0, green: c.1, blue: c.2, alpha: 1)
            ctx.fill(CGRect(x: CGFloat(i) * barW, y: 0, width: barW, height: CGFloat(height)))
        }

        // Big display-index block top-left so each monitor is visually distinct
        let blockColors: [(CGFloat, CGFloat, CGFloat)] = [
            (1, 0, 0),    // display 0 = red
            (0, 1, 0),    // display 1 = green
            (0, 0.4, 1)   // display 2 = blue
        ]
        let bc = blockColors[displayIndex % blockColors.count]
        ctx.setFillColor(red: bc.0, green: bc.1, blue: bc.2, alpha: 1)
        ctx.fill(CGRect(x: 60, y: CGFloat(height - 360), width: 600, height: 300))

        // Centered crosshair
        ctx.setStrokeColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.setLineWidth(4)
        ctx.move(to: CGPoint(x: 0, y: CGFloat(height) / 2))
        ctx.addLine(to: CGPoint(x: CGFloat(width), y: CGFloat(height) / 2))
        ctx.move(to: CGPoint(x: CGFloat(width) / 2, y: 0))
        ctx.addLine(to: CGPoint(x: CGFloat(width) / 2, y: CGFloat(height)))
        ctx.strokePath()

        return ctx.makeImage()
    }

    private func jpegEncode(image: CGImage, quality: CGFloat) -> Data? {
        let data = NSMutableData()
        let utType: CFString
        if #available(macOS 11.0, *) {
            utType = UTType.jpeg.identifier as CFString
        } else {
            utType = "public.jpeg" as CFString
        }
        guard let dest = CGImageDestinationCreateWithData(data, utType, 1, nil) else { return nil }
        let props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Strip every existing DQT (FF DB) segment from a JPEG byte stream and
    /// inject `replacement` immediately after the SOI marker. The replacement
    /// blob is expected to already be a complete JPEG segment(s) starting with
    /// `FF DB`.
    private func replaceDQTSegment(in jpeg: Data, with replacement: Data) -> Data {
        var output = Data()
        output.reserveCapacity(jpeg.count + replacement.count)

        // Copy SOI (FF D8) verbatim
        guard jpeg.count >= 2, jpeg[0] == 0xFF, jpeg[1] == 0xD8 else { return jpeg }
        output.append(contentsOf: [0xFF, 0xD8])
        output.append(replacement)

        var i = 2
        while i < jpeg.count - 1 {
            if jpeg[i] == 0xFF {
                let marker = jpeg[i + 1]
                if marker == 0xDB {
                    // Skip this DQT segment: FF DB <len-hi> <len-lo> ...
                    if i + 3 < jpeg.count {
                        let segLen = (Int(jpeg[i + 2]) << 8) | Int(jpeg[i + 3])
                        i += 2 + segLen
                        continue
                    }
                }
            }
            output.append(jpeg[i])
            i += 1
        }
        if i == jpeg.count - 1 { output.append(jpeg[i]) }
        return output
    }
    #endif
}
