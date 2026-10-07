#if GOTO_DEVTOOLS
import AppKit

/// Draws the app icon in code so the build needs no image assets.
enum AppIcon {
    static func writeIconset(to dir: String) {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for base in [16, 32, 128, 256, 512] {
            for scale in [1, 2] {
                let px = base * scale
                guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                                 colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { continue }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
                draw(in: NSRect(x: 0, y: 0, width: px, height: px))
                NSGraphicsContext.restoreGraphicsState()
                let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(name))
            }
        }
    }

    static func draw(in canvas: NSRect) {
        let s = canvas.width / 1024
        let tile = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
        let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185 * s, yRadius: 185 * s)

        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
        shadow.shadowBlurRadius = 24 * s
        shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
        shadow.set()
        Theme.rgb(0xF8F5F1).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()

        NSGraphicsContext.saveGraphicsState()
        tilePath.addClip()
        NSGradient(starting: Theme.rgb(0xFFFFFF), ending: Theme.rgb(0xF8F5F1))?.draw(in: tile, angle: -90)
        // Header strip echoing the panel.
        Theme.rgb(0x4059AD, 0.08).setFill()
        NSRect(x: tile.minX, y: tile.maxY - 150 * s, width: tile.width, height: 150 * s).fill()
        Theme.rgb(0x4059AD, 0.18).setFill()
        NSRect(x: tile.minX, y: tile.maxY - 152 * s, width: tile.width, height: 2 * s).fill()
        Theme.accent.setFill()
        NSBezierPath(roundedRect: NSRect(x: tile.minX + 70 * s, y: tile.maxY - 92 * s, width: 34 * s, height: 34 * s),
                     xRadius: 7 * s, yRadius: 7 * s).fill()
        for k in 0..<3 {
            Theme.rgb(0x6B9AC4, 0.35).setFill()
            NSBezierPath(roundedRect: NSRect(x: tile.minX + (140 + CGFloat(k) * 70) * s, y: tile.maxY - 84 * s,
                                             width: 50 * s, height: 18 * s), xRadius: 9 * s, yRadius: 9 * s).fill()
        }
        NSGraphicsContext.restoreGraphicsState()

        // Folder outline.
        let folder = NSBezierPath()
        let fx = 250 * s, fy = 270 * s, fw = 450 * s, fh = 320 * s
        folder.move(to: NSPoint(x: fx, y: fy + fh))
        folder.line(to: NSPoint(x: fx + 160 * s, y: fy + fh))
        folder.line(to: NSPoint(x: fx + 200 * s, y: fy + fh - 45 * s))
        folder.line(to: NSPoint(x: fx + fw, y: fy + fh - 45 * s))
        folder.line(to: NSPoint(x: fx + fw, y: fy))
        folder.line(to: NSPoint(x: fx, y: fy))
        folder.close()
        folder.lineJoinStyle = .round
        folder.lineWidth = 30 * s
        Theme.rgb(0x1C2826).setStroke()
        folder.stroke()

        // Sapphire lens with handle.
        let c = NSPoint(x: 640 * s, y: 330 * s)
        let r = 120 * s
        let handle = NSBezierPath()
        handle.move(to: NSPoint(x: c.x + r * 0.72, y: c.y - r * 0.72))
        handle.line(to: NSPoint(x: c.x + r * 1.55, y: c.y - r * 1.55))
        handle.lineWidth = 46 * s
        handle.lineCapStyle = .round
        Theme.accent.setStroke()
        handle.stroke()
        let lens = NSBezierPath(ovalIn: NSRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
        Theme.rgb(0xF8F5F1).setFill()
        lens.fill()
        lens.lineWidth = 40 * s
        lens.stroke()
    }
}
#endif
