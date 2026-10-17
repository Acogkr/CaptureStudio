import AppKit
import Carbon

@MainActor
func runInteractionRegressionTests() throws -> Int {
    var checks = 0, failures: [String] = []
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        checks += 1
        if !value() { failures.append(message) }
    }
    let suite = "CaptureStudio.InteractionTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let shortcuts = CaptureShortcuts(preferences: defaults)
    let original = shortcuts.bindings
    check(!shortcuts.set(CaptureKey(keyCode: UInt16(kVK_ANSI_S), modifiers: UInt32(cmdKey)), for: .screen)
        && shortcuts.bindings == original, "Command-S must remain available for Save")
    check(!shortcuts.set(CaptureKey(keyCode: UInt16(kVK_ANSI_R), modifiers: UInt32(cmdKey | shiftKey)), for: .window),
        "Command-Shift-R must remain available for Recents")
    check(!shortcuts.set(CaptureKey(keyCode: UInt16(kVK_ANSI_S), modifiers: UInt32(cmdKey | shiftKey)), for: .screen),
        "The standard Save As combination cannot be taken over either")

    func dragCase(_ name: String, interrupt: (EditorModel, CanvasView) -> Void, shouldCommit: Bool = false) {
        let model = EditorModel()
        model.tool = .rectangle
        let canvas = CanvasView(model: model)
        canvas.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
        func event(_ type: NSEvent.EventType, _ point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        let first = CGPoint(x: canvas.imageRect.minX + 60, y: canvas.imageRect.minY + 60)
        let last = CGPoint(x: first.x + 150, y: first.y + 100)
        canvas.mouseDown(with: event(.leftMouseDown, first))
        canvas.mouseDragged(with: event(.leftMouseDragged, last))
        interrupt(model, canvas)
        let baseline = model.state.id, marks = model.state.marks.count
        canvas.mouseUp(with: event(.leftMouseUp, last))
        check(shouldCommit ? model.state.marks.count == marks + 1
            : model.state.id == baseline && model.state.marks.count == marks,
            "Interrupted drag must not change the current image: " + name)
        model.tool = .rectangle
        canvas.mouseDown(with: event(.leftMouseDown, first))
        canvas.mouseDragged(with: event(.leftMouseDragged, last))
        let beforeNextStroke = model.state.marks.count
        canvas.mouseUp(with: event(.leftMouseUp, last))
        check(model.state.marks.count == beforeNextStroke + 1, "A fresh drag still works after: " + name)
    }
    dragCase("normal drag", interrupt: { _, _ in }, shouldCommit: true)
    dragCase("new capture replaces the image", interrupt: { model, _ in model.load(DemoImage.make(), title: "New capture") })
    dragCase("tool changes", interrupt: { model, _ in model.tool = .redact })
    dragCase("undo changes the image", interrupt: { model, _ in
        model.append(Mark(tool: .arrow, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 80, y: 80), color: .red, width: 4))
        model.undo()
    })
    dragCase("capture starts and is cancelled", interrupt: { model, canvas in
        model.isCapturing = true
        canvas.updateTextEditor() // Same view update used by SwiftUI when busy state changes.
        model.isCapturing = false
    })
    dragCase("window is resized", interrupt: { _, canvas in
        canvas.frame = CGRect(x: 0, y: 0, width: 1100, height: 750)
    })

    let model = EditorModel()
    let canvas = CanvasView(model: model)
    canvas.frame = CGRect(x: 0, y: 0, width: 1000, height: 700)
    func drag(from: CGPoint, to: CGPoint) {
        func event(_ type: NSEvent.EventType, _ imagePoint: CGPoint) -> NSEvent {
            let rect = canvas.imageRect
            let factor = rect.width / CGFloat(model.state.image.width)
            let point = CGPoint(x: rect.minX + imagePoint.x * factor, y: rect.minY + imagePoint.y * factor)
            return NSEvent.mouseEvent(with: type, location: canvas.convert(point, to: nil), modifierFlags: [],
                timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        canvas.mouseDown(with: event(.leftMouseDown, from))
        canvas.mouseDragged(with: event(.leftMouseDragged, to))
        canvas.mouseUp(with: event(.leftMouseUp, to))
    }
    for tool in [EditorTool.arrow, .rectangle, .redact] {
        model.tool = tool
        let earlier = model.state.marks.count
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        check(model.state.marks.count == earlier + 1 && model.state.marks.last?.tool == tool,
            "Uninterrupted canvas drawing still commits " + tool.rawValue)
    }
    model.tool = .select
    let beforeMove = model.state.marks.last!
    drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 200, y: 200))
    check(model.state.marks.last?.id == beforeMove.id
        && abs(model.state.marks.last!.start.x - beforeMove.start.x - 50) < 0.01,
        "Selection still moves the original annotation without adding another one")
    model.tool = .crop
    drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 500, y: 400))
    check(model.state.image.width < 1200 && model.state.image.height < 820 && model.state.marks.isEmpty,
        "An uninterrupted crop still applies through the canvas")
    model.undo()
    check(model.state.image.width == 1200 && model.state.image.height == 820 && model.state.marks.count == 3,
        "Undo after a crop restores the original image and annotations")
    if !failures.isEmpty {
        throw NSError(domain: "InteractionRegressionTests", code: failures.count,
            userInfo: [NSLocalizedDescriptionKey: failures.joined(separator: "\n")])
    }
    return checks
}
