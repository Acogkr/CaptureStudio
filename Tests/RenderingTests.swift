import AppKit

@MainActor
func runTests() {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        count += 1
    }
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.deviceRGB)!
    }
    do {
        count += try runInteractionRegressionTests()
        let image = DemoImage.make()
        let state = EditState(image: image)
        let rendered = try ImageRenderer.render(state)
        check(rendered.width == 1200 && rendered.height == 820, "Export preserves image size")
        let top = pixel(rendered, 30, 30), bottom = pixel(rendered, 30, 790)
        check(top.redComponent > top.greenComponent + 0.2, "Top of image is not flipped")
        check(abs(bottom.redComponent - bottom.greenComponent) < 0.05, "Bottom of image stays at bottom")
        let redact = Mark(tool: .redact, start: CGPoint(x: 410, y: 630), end: CGPoint(x: 700, y: 675), color: .clear, width: 4)
        var edited = state
        edited.marks = [redact]
        let redacted = try ImageRenderer.render(edited)
        for point in [(420, 640), (500, 650), (690, 670)] {
            let color = pixel(redacted, point.0, point.1)
            check(color.alphaComponent == 1 && color.redComponent < 0.15 && color.greenComponent < 0.15 && color.blueComponent < 0.15, "Redaction exported opaque at \(point)")
        }
        check(pixel(redacted, 900, 650).redComponent > 0.9, "Redaction leaves outside pixels unchanged")
        let png = try ImageRenderer.png(redacted)
        let decoded = NSBitmapImageRep(data: png)!.cgImage!
        check(pixel(decoded, 500, 650).redComponent < 0.15, "PNG retains opaque redaction")
        let cropped = try ImageRenderer.crop(edited, to: CGRect(x: 400, y: 620, width: 400, height: 100))
        check(cropped.image.width == 400 && cropped.image.height == 100, "Crop output dimensions")
        check(cropped.marks.isEmpty, "Crop includes annotations in pixels")
        check(pixel(cropped.image, 100, 30).redComponent < 0.15, "Crop keeps redaction in correct coordinates")
        let clipped = try ImageRenderer.crop(state, to: CGRect(x: -10, y: -10, width: 50, height: 50))
        check(clipped.image.width == 40 && clipped.image.height == 40, "Out of bounds crop clipped to image")
        do {
            _ = try ImageRenderer.crop(state, to: CGRect(x: 2000, y: 2000, width: 100, height: 100))
            check(false, "Invalid crop rejected")
        } catch { check(true, "Invalid crop rejected") }
        let model = EditorModel()
        model.append(redact)
        check(model.dirty && model.canUndo && model.state.marks.count == 1, "Adding mark makes document dirty")
        model.undo()
        check(!model.dirty && model.canRedo && model.state.marks.isEmpty, "Undo returns clean initial document")
        model.redo()
        check(model.dirty && model.state.marks.count == 1, "Redo restores mark")
        model.crop(to: CGRect(x: 400, y: 620, width: 400, height: 100))
        model.undo()
        check(model.state.image.width == 1200 && model.state.marks.count == 1, "Undo crop restores image and editable marks")
        model.selectedID = model.state.marks[0].id
        model.removeSelection()
        check(model.state.marks.isEmpty, "Selected annotation removed")
        model.undo()
        check(model.state.marks.count == 1, "Undo deletion restores annotation")
        model.append(Mark(tool: .rectangle, start: CGPoint(x: 20, y: 20), end: CGPoint(x: 100, y: 100), color: .systemRed, width: 4))
        check(!model.canRedo, "New edit clears redo branch")
        let arrow = Mark(tool: .arrow, start: CGPoint(x: 0, y: 0), end: CGPoint(x: 100, y: 100), color: .red, width: 4)
        check(arrow.contains(CGPoint(x: 50, y: 50), tolerance: 4), "Diagonal arrow selectable on line")
        check(!arrow.contains(CGPoint(x: 0, y: 90), tolerance: 4), "Arrow hit testing excludes empty bounding box")
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureStudio-Test-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try png.write(to: temporary)
        let loaded = try ImageRenderer.load(temporary)
        check(loaded.width == 1200 && loaded.height == 820, "File loading preserves full resolution")
        check(pixel(loaded, 500, 650).redComponent < 0.15, "File round-trip retains redaction")
        model.load(loaded, title: "Test")
        check(!model.dirty && !model.canUndo && !model.canRedo, "Loading image resets history")
        model.markUnsaved()
        check(model.dirty, "New captured image needs saving")
        let busy = EditorModel()
        busy.append(redact)
        busy.isCapturing = true
        let canvas = CanvasView(model: busy)
        let delete = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: "\u{7f}", charactersIgnoringModifiers: "\u{7f}", isARepeat: false, keyCode: 51)!
        canvas.keyDown(with: delete)
        check(busy.state.marks.count == 1, "Queued Delete cannot edit a disabled canvas during capture")
        busy.isCapturing = false
        canvas.keyDown(with: delete)
        check(busy.state.marks.isEmpty, "Delete works again after the busy operation finishes")
        count += try runHistoryTests()
        count += try runCaptureTests()
        count += try runPermissionRecoveryTests()
        count += try runClipboardTests()
        count += try runShortcutTests()
        count += try runSessionTests()
        count += try runConfigurableShortcutTests()
        count += try runTextEditingTests()
        count += try runArchiveSettingsTests()
        count += try runUpdateTests()
        count += try runLocalizationTests()
        count += try runWindowTests()
        count += try runLoginItemTests()
        print("\(count) checks passed: editing, archive retention and migration, clipboard, capture permissions, global shortcut, updates and localization.")
    } catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
