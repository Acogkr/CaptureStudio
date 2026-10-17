import AppKit
import SwiftUI

struct EditorCanvas: NSViewRepresentable {
    @ObservedObject var model: EditorModel
    @ObservedObject private var localization = Localization.shared
    func makeNSView(context: Context) -> CanvasView { CanvasView(model: model) }
    func updateNSView(_ view: CanvasView, context: Context) {
        view.model = model
        view.setAccessibilityLabel(L("Image Editor"))
        view.setAccessibilityHelp(L("Drag to add annotations. Press Command Z to undo."))
        view.updateTextEditor()
        view.needsDisplay = true
        view.window?.invalidateCursorRects(for: view)
    }
}

@MainActor
final class CanvasView: NSView {
    var model: EditorModel
    private var origin: CGPoint?
    private var draft: Mark?
    private var originalMark: Mark?
    private var cropRect: CGRect?
    private var didDrag = false
    private var gestureRevision: Int?
    private var gestureTool: EditorTool?
    private var gestureRect: CGRect?
    private var textEditor: InlineTextEditor?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityLabel(L("Image Editor"))
        setAccessibilityHelp(L("Drag to add annotations. Press Command Z to undo."))
        registerForDraggedTypes([.fileURL, .png, .tiff, .init("public.jpeg"), .init("public.heic")])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var imageRect: CGRect {
        let width = CGFloat(model.state.image.width), height = CGFloat(model.state.image.height)
        let scale = max(0.01, min((bounds.width - 80) / width, (bounds.height - 80) / height))
        let size = CGSize(width: width * scale, height: height * scale)
        return CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
    }
    private var scale: CGFloat { imageRect.width / CGFloat(model.state.image.width) }
    private func imagePoint(_ event: NSEvent, clamp: Bool = true) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let rect = imageRect
        let p = CGPoint(x: (point.x - rect.minX) / scale, y: (point.y - rect.minY) / scale)
        return clamp ? CGPoint(x: max(0, min(CGFloat(model.state.image.width), p.x)), y: max(0, min(CGFloat(model.state.image.height), p.y))) : p
    }
    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: model.tool == .select ? .arrow : model.tool == .text ? .iBeam : .crosshair)
    }
    override func layout() { super.layout(); updateTextEditor() }
    func updateTextEditor() {
        if origin != nil { _ = validateGesture() }
        guard let mark = model.editingText else { removeTextEditor(); return }
        textEditor?.update(mark: mark, imageRect: imageRect, scale: scale, canvasBounds: bounds)
        needsDisplay = true
    }
    private func editText(at point: CGPoint, existing: Mark? = nil) {
        textEditor?.finish()
        model.beginTextEditing(at: point, existing: existing)
        guard let mark = model.editingText else { return }
        let editor = InlineTextEditor(mark: mark, model: model)
        textEditor = editor
        setAccessibilityElement(false)
        editor.onFinish = { [weak self] in self?.removeTextEditor() }
        editor.onLayoutNeeded = { [weak self] in self?.updateTextEditor() }
        addSubview(editor)
        updateTextEditor()
        editor.focus()
    }
    private func removeTextEditor() {
        guard let editor = textEditor else { return }
        textEditor = nil
        let hadFocus = window?.firstResponder === editor.textView
        editor.detach()
        setAccessibilityElement(true)
        if hadFocus { window?.makeFirstResponder(self) }
        needsDisplay = true
    }
    private func cancelGesture() {
        origin = nil; draft = nil; originalMark = nil; cropRect = nil; didDrag = false
        gestureRevision = nil; gestureTool = nil; gestureRect = nil
        needsDisplay = true
    }
    private func validateGesture() -> Bool {
        guard origin != nil else { return false }
        // An unfinished stroke belongs to the image, tool and geometry at mouse-down.
        // Undo can restore the same state ID, so also track the edit revision.
        guard gestureRevision == model.revision, gestureTool == model.tool, gestureRect == imageRect,
              !model.isCapturing, !model.isUpdatingArchive, window?.attachedSheet == nil else {
            cancelGesture(); return false
        }
        return true
    }
    override func draw(_ dirtyRect: NSRect) {
        if origin != nil { _ = validateGesture() }
        NSColor.windowBackgroundColor.withAlphaComponent(0.65).setFill()
        bounds.fill()
        let rect = imageRect
        NSGraphicsContext.saveGraphicsState()
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
        shadow.shadowBlurRadius = 18
        shadow.shadowOffset = CGSize(width: 0, height: -3)
        shadow.set()
        NSColor.white.setFill()
        rect.fill()
        NSGraphicsContext.restoreGraphicsState()

        guard let cg = NSGraphicsContext.current?.cgContext else { return }
        NSGraphicsContext.saveGraphicsState()
        cg.translateBy(x: rect.minX, y: rect.minY)
        cg.scaleBy(x: scale, y: scale)
        cg.clip(to: CGRect(x: 0, y: 0, width: model.state.image.width, height: model.state.image.height))
        var preview = model.state
        if let editing = model.editingText { preview.marks.removeAll { $0.id == editing.id } }
        if let draft {
            if let index = preview.marks.firstIndex(where: { $0.id == draft.id }) { preview.marks[index] = draft }
            else { preview.marks.append(draft) }
        }
        ImageRenderer.draw(preview)
        if let selected = draft ?? model.selectedMark, model.tool == .select, model.editingText == nil {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: selected.bounds.insetBy(dx: -6 / scale, dy: -6 / scale))
            path.lineWidth = 1 / scale
            path.setLineDash([4 / scale, 3 / scale], count: 2, phase: 0)
            path.stroke()
        }
        if let cropRect {
            let shade = NSBezierPath(rect: CGRect(x: 0, y: 0, width: model.state.image.width, height: model.state.image.height))
            shade.append(NSBezierPath(rect: cropRect))
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.4).setFill()
            shade.fill()
            NSColor.white.setStroke()
            let border = NSBezierPath(rect: cropRect)
            border.lineWidth = 1 / scale
            border.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
    }
    override func mouseDown(with event: NSEvent) {
        cancelGesture()
        guard !model.isCapturing, !model.isUpdatingArchive, window?.attachedSheet == nil else { return }
        textEditor?.finish()
        guard imageRect.contains(convert(event.locationInWindow, from: nil)) else { return }
        window?.makeFirstResponder(self)
        let point = imagePoint(event)
        origin = point
        gestureRevision = model.revision; gestureTool = model.tool; gestureRect = imageRect
        didDrag = false
        switch model.tool {
        case .select:
            let selected = model.state.marks.reversed().first { $0.contains(point, tolerance: 7 / scale) }
            model.selectedID = selected?.id
            originalMark = selected
            if event.clickCount == 2, let selected, selected.tool == .text { editText(at: selected.start, existing: selected); origin = nil }
        case .text:
            let existing = model.state.marks.reversed().first { $0.tool == .text && $0.contains(point, tolerance: 4 / scale) }
            editText(at: existing?.start ?? point, existing: existing)
            origin = nil
        case .crop:
            model.selectedID = nil
        default:
            model.selectedID = nil
            draft = model.tool == .redact ? model.makeBlindMark(start: point, end: point)
                : Mark(tool: model.tool, start: point, end: point, color: model.color, width: model.stroke)
        }
        needsDisplay = true
    }
    override func mouseDragged(with event: NSEvent) {
        guard validateGesture(), let origin else { return }
        let point = imagePoint(event)
        didDrag = true
        if model.tool == .select, var moved = originalMark {
            let dx = point.x - origin.x, dy = point.y - origin.y
            moved.start.x += dx; moved.start.y += dy
            moved.end.x += dx; moved.end.y += dy
            draft = moved
        } else if model.tool == .crop {
            cropRect = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y), width: abs(point.x - origin.x), height: abs(point.y - origin.y))
        } else { draft?.end = point }
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        defer { cancelGesture() }
        guard validateGesture(), didDrag else { return }
        if let cropRect, cropRect.width * scale > 8, cropRect.height * scale > 8 { model.crop(to: cropRect) }
        else if let draft {
            if model.tool == .select { model.replace(draft) }
            else if hypot(draft.end.x - draft.start.x, draft.end.y - draft.start.y) * scale > 4,
                    draft.tool == .arrow || (draft.bounds.width * scale > 3 && draft.bounds.height * scale > 3) { model.append(draft) }
        }
    }
    override func keyDown(with event: NSEvent) {
        guard !model.isCapturing, !model.isUpdatingArchive, window?.attachedSheet == nil else { return }
        if event.keyCode == 51 || event.keyCode == 117 { model.removeSelection() }
        else if event.keyCode == 53 { cancelGesture(); model.selectedID = nil; model.tool = .select }
        else { super.keyDown(with: event) }
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !model.isCapturing, !model.isUpdatingArchive, window?.attachedSheet == nil else { return [] }
        return .copy
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard !model.isCapturing, !model.isUpdatingArchive, window?.attachedSheet == nil else { return false }
        model.importPasteboard(sender.draggingPasteboard)
        return true
    }
}
