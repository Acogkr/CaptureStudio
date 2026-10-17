import AppKit

enum AppIcon {
    static func make() -> NSImage {
        NSImage(size: NSSize(width: 1024, height: 1024), flipped: false) { _ in
            // Share Launchpad Studio's silhouette, neutral plate, and blue accent.
            let plate = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                xRadius: 188, yRadius: 188)
            NSGradient(starting: NSColor(white: 0.98, alpha: 1), ending: NSColor(white: 0.86, alpha: 1))!
                .draw(in: plate, angle: -90)
            NSColor(white: 0.72, alpha: 0.6).setStroke()
            plate.lineWidth = 4
            plate.stroke()

            NSColor(white: 0.43, alpha: 1).setStroke()
            let frame = NSBezierPath()
            frame.lineWidth = 52
            frame.lineCapStyle = .round
            frame.lineJoinStyle = .round
            for (x, y, dx, dy) in [(282.0, 742.0, 1.0, -1.0), (742, 742, -1, -1),
                                   (282, 282, 1, 1), (742, 282, -1, 1)] {
                frame.move(to: CGPoint(x: x, y: y + dy * 144))
                frame.line(to: CGPoint(x: x, y: y))
                frame.line(to: CGPoint(x: x + dx * 144, y: y))
            }
            frame.stroke()
            NSColor(red: 0.25, green: 0.49, blue: 0.84, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 432, y: 432, width: 160, height: 160)).fill()
            return true
        }
    }
}
