import AppKit

enum DemoImage {
    static func make() -> CGImage {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1200, pixelsHigh: 820, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 4800, bitsPerPixel: 32)!
        let context = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.cgContext.translateBy(x: 0, y: 820)
        context.cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context.cgContext, flipped: true)
        NSColor.white.setFill(); CGRect(x: 0, y: 0, width: 1200, height: 820).fill()
        NSColor(calibratedWhite: 0.962, alpha: 1).setFill(); CGRect(x: 0, y: 0, width: 250, height: 820).fill()
        NSColor(calibratedWhite: 0.89, alpha: 1).setFill(); CGRect(x: 249, y: 0, width: 1, height: 820).fill()
        let ink = NSColor(calibratedWhite: 0.16, alpha: 1)
        let muted = NSColor(calibratedWhite: 0.53, alpha: 1)
        func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ weight: NSFont.Weight = .regular, _ color: NSColor? = nil) {
            (string as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color ?? ink])
        }
        for (i, color) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            color.withAlphaComponent(0.85).setFill()
            NSBezierPath(ovalIn: CGRect(x: 24 + i * 25, y: 24, width: 13, height: 13)).fill()
        }
        text(L("Notes"), 28, 94, 24, .semibold)
        text(L("Personal"), 28, 149, 13, .medium, muted)
        NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 16, y: 182, width: 218, height: 44), xRadius: 7, yRadius: 7).fill()
        text(L("Weekend Plans"), 36, 193, 16, .medium)
        text(L("Reading List"), 36, 248, 16, .regular, muted)
        text(L("Ideas"), 36, 301, 16, .regular, muted)
        text(L("Sample Document"), 28, 767, 12, .regular, muted)
        text(L("October 17, 2026"), 320, 80, 15, .regular, muted)
        text(L("Weekend Plans"), 320, 119, 42, .semibold)
        text(L("Explore a few places on my list."), 320, 192, 19, .regular, muted)
        NSColor(calibratedWhite: 0.91, alpha: 1).setFill(); CGRect(x: 320, y: 245, width: 800, height: 1).fill()
        text(L("Saturday"), 320, 281, 20, .semibold)
        for (index, row) in [("11:00", L("Visit a bookshop")), ("13:00", L("Lunch with a friend")), ("15:30", L("Walk in the park"))].enumerated() {
            let y = CGFloat(338 + index * 64)
            NSColor(calibratedWhite: 0.79, alpha: 1).setStroke()
            let check = NSBezierPath(roundedRect: CGRect(x: 322, y: y + 3, width: 20, height: 20), xRadius: 4, yRadius: 4)
            check.lineWidth = 1.5; check.stroke()
            text(row.0, 363, y, 18, .regular, muted)
            text(row.1, 452, y, 19)
        }
        NSColor(calibratedWhite: 0.97, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 320, y: 575, width: 800, height: 122), xRadius: 10, yRadius: 10).fill()
        text(L("Reservation"), 344, 596, 15, .semibold)
        text(L("Email"), 344, 641, 15, .regular, muted)
        text("hello@example.com", 420, 640, 16)
        text(L("A sample image to try the editing tools."), 320, 760, 12, .regular, muted)
        return rep.cgImage!
    }
}
