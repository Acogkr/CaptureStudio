import AppKit

@MainActor
func runTextEditingTests() throws -> Int {
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        guard (try? value()) == true else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        count += 1
    }
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let model = EditorModel(clipboard: ImageClipboard(pasteboard: board))
    let point = CGPoint(x: 150, y: 150)
    let initial = model.state
    model.beginTextEditing(at: point)
    check(!model.canUndo && !model.dirty && model.state.marks.isEmpty, "An empty inline field is not a document edit")
    model.updateText("바로")
    model.updateText("바로 입력\n두 번째 줄")
    check(model.state.marks[0].text == "바로 입력\n두 번째 줄" && model.state.marks[0].start == point,
        "Multiline Korean text updates at the clicked image position")
    check(try board.data(forType: .png) == ImageRenderer.png(ImageRenderer.render(model.state)),
        "Text is copied as a flattened image before leaving the inline field")
    model.finishTextEditing()
    model.undo()
    check(model.state.id == initial.id && !model.canUndo, "One undo removes the entire completed typing session")
    model.redo()
    check(model.state.marks[0].text == "바로 입력\n두 번째 줄", "Redo restores all typed lines")
    let existing = model.state.marks[0]
    let beforeEdit = model.state.id
    model.beginTextEditing(at: existing.start, existing: existing)
    model.updateText("취소할 내용")
    model.finishTextEditing(cancelled: true)
    check(model.state.id == beforeEdit && model.state.marks[0].text == existing.text,
        "Escape restores existing text instead of deleting it")
    check(try board.data(forType: .png) == ImageRenderer.png(ImageRenderer.render(model.state)),
        "Cancelling restores the previous clipboard image")
    model.beginTextEditing(at: point)
    model.updateText("새 글자 취소")
    model.finishTextEditing(cancelled: true)
    check(model.state.id == beforeEdit && model.state.marks.count == 1, "Escape discards a new text annotation")
    model.beginTextEditing(at: existing.start, existing: existing)
    model.updateText("")
    model.finishTextEditing()
    check(model.state.marks.isEmpty, "Clearing an existing text field removes its annotation")
    model.undo()
    check(model.state.marks[0].text == existing.text, "Cleared text can be restored with undo")
    model.beginTextEditing(at: existing.start, existing: existing)
    model.fontSize = 48; model.color = .systemBlue
    check(model.state.marks[0].fontSize == 48 && model.state.marks[0].color == .systemBlue,
        "Inline text reflects font size and color controls immediately")
    model.tool = .rectangle
    check(model.editingText == nil && model.state.marks[0].fontSize == 48, "Changing tools completes text editing")
    model.undo()
    check(model.state.marks[0].fontSize == existing.fontSize, "Text and style changes form one undo step")
    model.beginTextEditing(at: point)
    model.updateText(" \n ")
    model.finishTextEditing()
    check(model.state.marks.count == 1 && model.canRedo, "Blank text does not create an undo step or discard redo")
    model.beginTextEditing(at: point)
    model.updateText(String(repeating: "가", count: 1002))
    check(model.state.marks.last?.text.count == 1000, "Text limit preserves complete Unicode characters")
    model.finishTextEditing(cancelled: true)

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureStudio-TextTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let store = HistoryStore(root: folder)
    let persistent = EditorModel(history: store)
    persistent.beginTextEditing(at: point)
    persistent.updateText("입력 중인 글자도 보관")
    check(persistent.flushHistory() && persistent.editingText == nil, "Flushing history completes an active text session")
    let reopened = EditorModel(history: store)
    check(reopened.state.marks.first?.text == "입력 중인 글자도 보관", "Typed text survives app restart")

    let viewModel = EditorModel()
    viewModel.beginTextEditing(at: point)
    let editor = InlineTextEditor(mark: viewModel.editingText!, model: viewModel)
    editor.update(mark: viewModel.editingText!, imageRect: CGRect(x: 40, y: 40, width: 600, height: 410),
        scale: 0.5, canvasBounds: CGRect(x: 0, y: 0, width: 700, height: 500))
    check(editor.frame.minX == 110 && editor.frame.minY == 110 && editor.textView.font?.pointSize == 14,
        "Inline field position and font track the displayed image scale")
    editor.textView.string = "두 줄\n입력"
    editor.textDidChange(Notification(name: NSText.didChangeNotification))
    check(viewModel.state.marks.first?.text == "두 줄\n입력", "Native text delegate updates the document")
    check(editor.textView(editor.textView, doCommandBy: #selector(NSResponder.insertNewline(_:))) && viewModel.editingText == nil,
        "Enter completes inline input without opening a modal dialog")
    return count
}
