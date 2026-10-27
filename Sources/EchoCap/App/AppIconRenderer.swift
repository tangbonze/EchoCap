import AppKit
import CoreGraphics
import Foundation

/// Draws the EchoCap app icon and writes it out as an `.icns`.
///
/// The icon is generated rather than hand-drawn so it stays reproducible and
/// so the same vector description can drive every size macOS asks for.
enum AppIconRenderer {

    /// macOS wants every square size in this set.
    static let requiredSizes = [16, 32, 64, 128, 256, 512, 1024]

    /// Render the icon at `size` points and return the PNG data.
    static func pngData(size: CGFloat) -> Data? {
        let scale = size / 1024.0
        guard let context = CGContext(
            data: nil,
            width: Int(size),
            height: Int(size),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.scaleBy(x: scale, y: scale)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high

        drawIcon(in: context)

        guard let image = context.makeImage() else { return nil }
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: size, height: size)
        return rep.representation(using: .png, properties: [:])
    }

    /// The icon artwork, drawn in a 1024×1024 coordinate space.
    private static func drawIcon(in context: CGContext) {
        let canvas = CGRect(x: 0, y: 0, width: 1024, height: 1024)

        // macOS Big Sur style: the art sits inside a rounded square with
        // generous margins.
        let side: CGFloat = 824
        let inset = (1024 - side) / 2
        let plate = CGRect(x: inset, y: inset, width: side, height: side)
        let radius = side * 0.2237

        let platePath = CGPath(roundedRect: plate, cornerWidth: radius, cornerHeight: radius, transform: nil)

        // Background gradient.
        context.saveGState()
        context.addPath(platePath)
        context.clip()
        let colors = [
            CGColor(red: 0.38, green: 0.28, blue: 0.92, alpha: 1.0),
            CGColor(red: 0.16, green: 0.12, blue: 0.52, alpha: 1.0),
        ] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: plate.minX, y: plate.maxY),
                end: CGPoint(x: plate.maxX, y: plate.minY),
                options: []
            )
        }

        // A soft highlight across the top.
        if let highlight = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.22),
                CGColor(red: 1, green: 1, blue: 1, alpha: 0.0),
            ] as CFArray,
            locations: [0, 1]
        ) {
            context.drawLinearGradient(
                highlight,
                start: CGPoint(x: plate.midX, y: plate.maxY),
                end: CGPoint(x: plate.midX, y: plate.midY),
                options: []
            )
        }
        context.restoreGState()

        // A hint of the plate edge so it reads well on light backgrounds.
        context.saveGState()
        context.addPath(platePath)
        context.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.16))
        context.setLineWidth(6)
        context.strokePath()
        context.restoreGState()

        // --- Foreground: five symmetric waveform bars, dead centre ---
        //
        // Scheme A: pure sound. No caption lines, no lettering — the bars are
        // vertically and horizontally symmetric around the plate centre, so
        // nothing reads as off-balance at small sizes.
        let cx = plate.midX
        let heights: [CGFloat] = [180, 300, 420, 300, 180]
        let barWidth: CGFloat = 52
        let step: CGFloat = 114 // spacing + barWidth: the distance between bar starts
        let totalWidth = CGFloat(heights.count - 1) * step + barWidth
        var x = cx - totalWidth / 2

        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.97))
        for height in heights {
            let rect = CGRect(x: x, y: plate.midY - height / 2, width: barWidth, height: height)
            let path = CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil)
            context.addPath(path)
            context.fillPath()
            x += step
        }
    }

    /// Write an `.icns` file containing every required size.
    static func writeICNS(to url: URL, iconsetDirectory: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: iconsetDirectory.path) {
            try fm.removeItem(at: iconsetDirectory)
        }
        try fm.createDirectory(at: iconsetDirectory, withIntermediateDirectories: true)

        for size in requiredSizes {
            guard let data = pngData(size: CGFloat(size)) else {
                throw NSError(domain: "AppIconRenderer", code: 1)
            }
            // 1x and 2x variants.
            let oneX = iconsetDirectory.appendingPathComponent("icon_\(size)x\(size).png")
            try data.write(to: oneX)
            if size < 1024 {
                guard let big = pngData(size: CGFloat(size * 2)) else { continue }
                try big.write(to: iconsetDirectory.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
            }
        }

        // iconutil turns the iconset into a multi-resolution .icns.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
        process.arguments = ["-c", "icns", iconsetDirectory.path, "-o", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            let message = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "AppIconRenderer", code: Int(process.terminationStatus), userInfo: [
                NSLocalizedDescriptionKey: "iconutil 失败: \(message)",
            ])
        }
    }
}
