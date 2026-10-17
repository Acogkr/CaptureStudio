import AppKit

@MainActor
func runClipboardTests() throws -> Int {
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        guard (try? value()) == true else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        count += 1
    }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let clipboard = ImageClipboard(pasteboard: board)
    let model = EditorModel(clipboard: clipboard)
    let cg = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.setFillColor(NSColor.white.cgColor)
    cg.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    let image = cg.makeImage()!
    func copied(_ type: NSPasteboard.PasteboardType = .png) throws -> CGImage {
        guard let data = board.data(forType: type) else { throw EditorError.render }
        return try ImageRenderer.load(data)
    }
    func red(_ image: CGImage, _ x: Int = 20, _ y: Int = 20) -> CGFloat {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!.redComponent
    }
    check(model.loadCapture(image, title: "Capture"), "Capture automatically publishes image")
    check(board.types?.contains(.png) == true && board.types?.contains(.tiff) == true, "Automatic copy supports PNG and TIFF clients")
    check(try copied().width == 64, "Capture can be pasted immediately without opening editor")
    var mask = Mark(tool: .redact, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 30, y: 30), color: .clear, width: 4)
    model.append(mask)
    check(try red(copied()) < 0.15, "An edit updates the clipboard immediately")
    check(try red(copied(.tiff)) < 0.15, "TIFF paste retains opaque redaction")
    check(board.types?.contains(.fileURL) != true, "Clipboard exposes flattened image only, never original path")
    model.undo()
    check(try red(copied()) > 0.95, "Undo updates the clipboard")
    model.redo()
    check(try red(copied()) < 0.15, "Redo updates the clipboard")
    mask.start = CGPoint(x: 35, y: 35); mask.end = CGPoint(x: 55, y: 55)
    model.replace(mask)
    check(try red(copied()) > 0.95 && red(copied(), 45, 45) < 0.15, "Moving a mark replaces the copied snapshot")
    model.selectedID = mask.id
    model.removeSelection()
    check(try red(copied(), 45, 45) > 0.95, "Deleting a mark updates the clipboard")
    model.crop(to: CGRect(x: 0, y: 0, width: 32, height: 24))
    check(try copied().width == 32 && copied().height == 24, "Crop is immediately reflected in the clipboard")
    let changeCount = board.changeCount
    model.load(image, title: "Another photo")
    check(board.changeCount == changeCount, "Opening a photo without editing does not overwrite the clipboard")
    check(model.finishClipboard(), "Pending image data is materialized before exit")
    board.clearContents(); board.setString("Copied somewhere else", forType: .string)
    check(model.finishClipboard() && board.string(forType: .string) == "Copied somewhere else", "Quitting does not overwrite a later copy from another app")
    model.append(mask)
    check(try red(copied(), 45, 45) < 0.15, "A deliberate new edit resumes automatic copy")

    // A real producer process exits; the image must outlive its lazy provider.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
    process.arguments = ["--clipboard-producer", board.name.rawValue]
    try process.run(); process.waitUntilExit()
    check(process.terminationStatus == 0, "Clipboard producer exits cleanly")
    check(try copied().width == 1200 && copied(.tiff).height == 820, "Both clipboard formats survive app termination")

    let visible = CGRect(x: -1440, y: 30, width: 1440, height: 870)
    let preview = CapturePreviewController.frame(in: visible)
    check(visible.contains(preview) && preview.maxX == visible.maxX - 20 && preview.minY == visible.minY + 20,
          "Preview stays inside the chosen display and clear of the Dock")
    return count
}
