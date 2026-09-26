import AppKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        guard
            let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
            let context = NSGraphicsContext(bitmapImageRep: rep)
        else { continue }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.cgContext.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
        let outer = NSBezierPath(roundedRect: NSRect(x: 50, y: 50, width: 924, height: 924), xRadius: 208, yRadius: 208)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        outer.fill()
        let disc = NSBezierPath(ovalIn: NSRect(x: 214, y: 214, width: 596, height: 596))
        let gradient = NSGradient(colors: [
            NSColor(calibratedWhite: 0.90, alpha: 1), NSColor(calibratedWhite: 0.45, alpha: 1),
            NSColor(calibratedWhite: 0.80, alpha: 1),
        ])
        gradient?.draw(in: disc, angle: 45)
        let highlight = NSBezierPath()
        highlight.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: 269, startAngle: 35, endAngle: 145)
        highlight.lineWidth = 58
        NSColor.systemOrange.setStroke()
        highlight.stroke()
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 433, y: 433, width: 158, height: 158)).fill()
        let inner = NSBezierPath(ovalIn: NSRect(x: 402, y: 402, width: 220, height: 220))
        inner.lineWidth = 4
        NSColor(calibratedWhite: 0.25, alpha: 1).setStroke()
        inner.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        if let data = rep.representation(using: .png, properties: [:]) {
            try data.write(to: output.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
        }
    }
}
