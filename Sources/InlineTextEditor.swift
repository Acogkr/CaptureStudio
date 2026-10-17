import AppKit

@MainActor
final class InlineTextEditor: NSView, NSTextViewDelegate {
    let textView = AnnotationTextView(frame: .zero)
    private let scrollView = NSScrollView(frame: .zero)
    private let markID: UUID
    private weak var model: EditorModel?
    private var ending = false
    var onFinish: (() -> Void)?

    init(mark: Mark, model: EditorModel) {
        markID = mark.id
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.cornerRadius = 3
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        scrollView.drawsBackground = false
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.containerSize = NSSize(width: 1_000_000, height: 1_000_000)
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.string = mark.text
        textView.setAccessibilityLabel(L("Text on Image"))
        textView.setAccessibilityHelp(L("Enter to finish, Shift Enter for a new line, Escape to cancel."))
        textView.delegate = self
        textView.onResign = { [weak self] in self?.finish() }
        scrollView.documentView = textView
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(mark: Mark, imageRect: CGRect, scale: CGFloat, canvasBounds: CGRect) {
        guard mark.id == markID else { return }
        textView.setAccessibilityLabel(L("Text on Image"))
        textView.setAccessibilityHelp(L("Enter to finish, Shift Enter for a new line, Escape to cancel."))
        let font = NSFont.systemFont(ofSize: mark.fontSize * scale, weight: .semibold)
        if textView.font != font { textView.font = font }
        if textView.textColor != mark.color { textView.textColor = mark.color }
        textView.insertionPointColor = .controlAccentColor
        textView.typingAttributes = [.font: font, .foregroundColor: mark.color]
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let used = textView.layoutManager?.usedRect(for: textView.textContainer!) ?? .zero
        let lineHeight = textView.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize * 1.3
        let content = NSSize(width: max(120, ceil(used.maxX) + 4), height: max(lineHeight, ceil(used.maxY)))
        let point = CGPoint(x: imageRect.minX + mark.start.x * scale, y: imageRect.minY + mark.start.y * scale)
        // The text stays anchored to the image. Long lines scroll within the remaining canvas space.
        let visible = NSSize(width: min(content.width, max(16, canvasBounds.maxX - point.x - 8)),
            height: min(content.height, max(lineHeight, canvasBounds.maxY - point.y - 8)))
        frame = CGRect(x: point.x - 5, y: point.y - 5, width: visible.width + 10, height: visible.height + 10)
        scrollView.frame = bounds.insetBy(dx: 5, dy: 5)
        textView.frame = CGRect(origin: .zero, size: content)
        textView.needsDisplay = true
    }
    func focus() {
        window?.makeFirstResponder(textView)
        textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
        textView.scrollRangeToVisible(textView.selectedRange())
    }
    func textDidChange(_ notification: Notification) {
        guard !ending else { return }
        // Keep the native field intact while the input method composes Korean/Japanese text.
        model?.updateText(textView.string)
        onLayoutNeeded?()
        textView.scrollRangeToVisible(textView.selectedRange())
    }
    var onLayoutNeeded: (() -> Void)?
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard let replacementString else { return true }
        if textView.hasMarkedText() { return true }
        let next = (textView.string as NSString).replacingCharacters(in: affectedCharRange, with: replacementString)
        return next.count <= 1000 || next.count < textView.string.count
    }
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { finish(cancelled: true); return true }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true { textView.insertNewlineIgnoringFieldEditor(nil) }
            else { finish() }
            return true
        }
        if commandSelector == #selector(NSResponder.insertTab(_:)) { finish(); return true }
        return false
    }
    func finish(cancelled: Bool = false) {
        guard !ending else { return }
        ending = true
        if model?.editingText?.id == markID {
            if !cancelled { model?.updateText(textView.string) }
            model?.finishTextEditing(cancelled: cancelled)
        }
        onFinish?()
    }
    func detach() {
        ending = true
        textView.onResign = nil
        textView.delegate = nil
        removeFromSuperview()
    }
}

@MainActor
final class AnnotationTextView: NSTextView {
    var onResign: (() -> Void)?
    private let textUndoManager = UndoManager()
    override var undoManager: UndoManager? { textUndoManager }
    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { onResign?() }
        return result
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        if string.isEmpty, !hasMarkedText() {
            (L("Type text") as NSString).draw(at: .zero, withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.secondaryLabelColor
            ])
        }
    }
}
