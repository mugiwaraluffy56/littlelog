// Renders the monochrome app icon and writes every size the AppIcon set needs.
// Usage: swift scripts/make-icon.swift <AppIcon.appiconset directory>
import AppKit

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <appiconset-dir>\n".utf8))
    exit(64)
}
let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)

func renderIcon(pixels: Int) throws -> Data {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: rep) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let scale = CGFloat(pixels) / 1024

    // macOS icon grid: an 824pt rounded square centred in a 1024pt canvas.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824).applying(.init(scaleX: scale, y: scale))
    let shape = NSBezierPath(roundedRect: body, xRadius: 185 * scale, yRadius: 185 * scale)
    NSColor(calibratedWhite: 0.11, alpha: 1).setFill()
    shape.fill()
    NSColor(calibratedWhite: 1, alpha: 0.08).setStroke()
    shape.lineWidth = 4 * scale
    shape.stroke()

    // A short checklist: an open circle and a ruled line per row, fading downwards.
    let ink = NSColor(calibratedWhite: 0.94, alpha: 1)
    let lineHeight = 30 * scale
    let circleSize = 64 * scale
    let rows: [(centerY: CGFloat, width: CGFloat, alpha: CGFloat)] = [
        (630, 380, 1.0),
        (512, 320, 0.6),
        (394, 250, 0.35),
    ]
    for row in rows {
        let color = ink.withAlphaComponent(row.alpha)
        let centerY = row.centerY * scale
        let circle = NSBezierPath(ovalIn: NSRect(
            x: 262 * scale,
            y: centerY - circleSize / 2,
            width: circleSize,
            height: circleSize
        ))
        circle.lineWidth = 11 * scale
        color.setStroke()
        circle.stroke()

        color.setFill()
        let line = NSRect(x: 382 * scale, y: centerY - lineHeight / 2, width: row.width * scale, height: lineHeight)
        NSBezierPath(roundedRect: line, xRadius: lineHeight / 2, yRadius: lineHeight / 2).fill()
    }

    NSGraphicsContext.restoreGraphicsState()
    guard let png = rep.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    return png
}

let sizes = [16, 32, 64, 128, 256, 512, 1024]
do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for size in sizes {
        let url = outputDirectory.appendingPathComponent("icon_\(size).png")
        try renderIcon(pixels: size).write(to: url)
        print("wrote \(url.lastPathComponent)")
    }
} catch {
    FileHandle.standardError.write(Data("failed to render icon: \(error)\n".utf8))
    exit(1)
}
