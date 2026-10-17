import AppKit
import UniformTypeIdentifiers

enum EditorTool: String, CaseIterable, Identifiable, Codable {
    case select, arrow, rectangle, text, redact, crop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return L("Select")
        case .arrow: return L("Arrow")
        case .rectangle: return L("Rectangle")
        case .text: return L("Text")
        case .redact: return L("Redact")
        case .crop: return L("Crop")
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .text: return "textformat"
        case .redact: return "rectangle.fill"
        case .crop: return "crop"
        }
    }
    var hint: String {
        switch self {
        case .select: return L("Click an annotation to select it, then drag to move it.")
        case .arrow: return L("Drag from the start point to what you want to highlight.")
        case .rectangle: return L("Drag around the area you want to highlight.")
        case .text: return L("Click the image to type. Enter to finish, Shift+Enter for a new line.")
        case .redact: return L("Choose a style, then drag over the area to hide.")
        case .crop: return L("Drag over the area to keep. You can undo the crop.")
        }
    }
}

enum BlindStyle: String, CaseIterable, Identifiable, Codable {
    case solid, mosaic
    var id: String { rawValue }
    var title: String { self == .solid ? L("Cover") : L("Mosaic") }
}

struct Mark: Identifiable {
    var id = UUID()
    var tool: EditorTool
    var start: CGPoint
    var end: CGPoint
    var color: NSColor
    var width: CGFloat
    var text = ""
    var fontSize: CGFloat = 32
    var blindStyle: BlindStyle = .solid
    var blockSize: CGFloat = 24

    var bounds: CGRect {
        if tool == .text {
            let size = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold)])
            return CGRect(origin: start, size: CGSize(width: ceil(size.width) + 4, height: ceil(size.height) + 4))
        }
        return CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
    }
    func contains(_ point: CGPoint, tolerance: CGFloat) -> Bool {
        if tool == .arrow {
            let dx = end.x - start.x, dy = end.y - start.y
            let length = dx * dx + dy * dy
            guard length > 0 else { return false }
            let t = max(0, min(1, ((point.x - start.x) * dx + (point.y - start.y) * dy) / length))
            return hypot(point.x - start.x - t * dx, point.y - start.y - t * dy) <= tolerance + width
        }
        return bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
    }
}

struct EditState {
    var id = UUID()
    var image: CGImage
    var marks: [Mark] = []
}

enum ImageRenderer {
    static let maxPixels = 40_000_000
    static func load(_ url: URL) throws -> CGImage {
        guard url.isFileURL, let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw EditorError.image }
        return try load(source)
    }
    static func load(_ data: Data) throws -> CGImage {
        guard data.count <= 220_000_000, let source = CGImageSourceCreateWithData(data as CFData, nil) else { throw EditorError.image }
        return try load(source)
    }
    private static func load(_ source: CGImageSource) throws -> CGImage {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, Double(width) * Double(height) <= Double(maxPixels),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: max(width, height)
              ] as CFDictionary) else { throw EditorError.image }
        return image
    }

    static func render(_ state: EditState) throws -> CGImage {
        let width = state.image.width, height = state.image.height
        guard let cg = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorError.render }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        cg.translateBy(x: 0, y: CGFloat(height))
        cg.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        draw(state)
        guard let output = cg.makeImage() else { throw EditorError.render }
        return output
    }

    // Both the canvas and export use the same top-left image coordinate system.
    static func draw(_ state: EditState) {
        let size = CGSize(width: state.image.width, height: state.image.height)
        NSImage(cgImage: state.image, size: size).draw(in: CGRect(origin: .zero, size: size),
            from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        for mark in state.marks {
            if mark.tool == .redact, mark.blindStyle == .mosaic { drawMosaic(mark, image: state.image) }
            else { drawMark(mark) }
        }
        for mark in state.marks where mark.tool == .redact && mark.blindStyle == .solid { drawMark(mark) }
    }

    static func drawMark(_ mark: Mark) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        mark.color.setStroke()
        mark.color.setFill()
        let path = NSBezierPath()
        path.lineWidth = mark.width
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch mark.tool {
        case .arrow:
            path.move(to: mark.start)
            path.line(to: mark.end)
            path.stroke()
            let angle = atan2(mark.end.y - mark.start.y, mark.end.x - mark.start.x)
            let head = max(14, mark.width * 3.5)
            let tip = NSBezierPath()
            tip.move(to: CGPoint(x: mark.end.x - cos(angle - .pi / 6) * head, y: mark.end.y - sin(angle - .pi / 6) * head))
            tip.line(to: mark.end)
            tip.line(to: CGPoint(x: mark.end.x - cos(angle + .pi / 6) * head, y: mark.end.y - sin(angle + .pi / 6) * head))
            tip.lineWidth = mark.width
            tip.lineCapStyle = .round
            tip.lineJoinStyle = .round
            tip.stroke()
        case .rectangle:
            NSBezierPath(roundedRect: mark.bounds, xRadius: 3, yRadius: 3).withWidth(mark.width).stroke()
        case .redact:
            // Always opaque, regardless of annotation color or opacity.
            NSColor(calibratedWhite: 0.08, alpha: 1).setFill()
            mark.bounds.integral.fill()
        case .text:
            (mark.text as NSString).draw(at: mark.start, withAttributes: [
                .font: NSFont.systemFont(ofSize: mark.fontSize, weight: .semibold), .foregroundColor: mark.color
            ])
        case .select, .crop: break
        }
    }

    static func png(_ image: CGImage) throws -> Data {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { throw EditorError.render }
        return data
    }
    // Sample only the selected source region. Shrink and expand without smoothing.
    // Opaque redactions are drawn again last, so later mosaic marks cannot reveal them.
    static func drawMosaic(_ mark: Mark, image: CGImage) {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let rect = mark.bounds.integral.intersection(bounds)
        guard !rect.isNull, rect.width >= 1, rect.height >= 1, let part = image.cropping(to: rect) else { return }
        let block = max(8, min(96, mark.blockSize))
        let width = max(1, Int(ceil(rect.width / block))), height = max(1, Int(ceil(rect.height / block)))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .low
        context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let small = context.makeImage() else { return }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.imageInterpolation = .none
        NSImage(cgImage: small, size: rect.size).draw(in: rect, from: .zero, operation: .copy,
            fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none.rawValue])
        NSGraphicsContext.restoreGraphicsState()
    }

    static func thumbnail(_ image: CGImage) throws -> Data {
        let factor = min(1, 240 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * factor)), height = max(1, Int(CGFloat(image.height) * factor))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw EditorError.render }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = context.makeImage() else { throw EditorError.render }
        return try png(result)
    }
    static func crop(_ state: EditState, to rect: CGRect) throws -> EditState {
        let bounds = CGRect(x: 0, y: 0, width: state.image.width, height: state.image.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 2, clipped.height >= 2,
              let image = try render(state).cropping(to: clipped) else { throw EditorError.crop }
        return EditState(image: image)
    }
}

private extension NSBezierPath {
    func withWidth(_ value: CGFloat) -> NSBezierPath { lineWidth = value; return self }
}

enum EditorError: LocalizedError {
    case image, render, crop, capture
    var errorDescription: String? {
        switch self {
        case .image: return L("Could not open this image. Use PNG, JPEG, HEIC or another supported format, up to 40 megapixels.")
        case .render: return L("Could not render the image. Please try again.")
        case .crop: return L("Select a slightly larger area to crop.")
        case .capture: return L("No image was captured. Try again. Your previous image has not changed.")
        }
    }
}
