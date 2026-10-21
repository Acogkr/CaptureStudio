import AppKit
import Carbon

@MainActor
func runWindowTests() throws -> Int {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        count += 1
    }
    let suite = "CaptureStudio.WindowTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let clipboard = NSPasteboard(name: .init(suite))
    defer { clipboard.releaseGlobally() }
    let model = EditorModel(clipboard: ImageClipboard(pasteboard: clipboard))
    let updates = UpdateChecker(defaults: defaults, loader: { _ in })
    let shortcuts = CaptureShortcuts(preferences: defaults)
    defer { shortcuts.stop() }
    let delegate = AppDelegate(model: model, updates: updates, shortcuts: shortcuts)
    let editor = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 620),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
        styleMask: [.titled, .closable], backing: .buffered, defer: false)
    editor.isReleasedWhenClosed = false
    settings.isReleasedWhenClosed = false
    delegate.window = editor; model.window = editor; delegate.settingsWindow = settings
    editor.delegate = delegate; settings.delegate = delegate
    let mark = Mark(tool: .rectangle, start: CGPoint(x: 10, y: 10), end: CGPoint(x: 100, y: 100), color: .red, width: 4)
    model.append(mark)
    let editedID = model.state.id
    let commands: [Selector] = [#selector(AppDelegate.undo), #selector(AppDelegate.redo),
        #selector(AppDelegate.deleteMark), #selector(AppDelegate.copyImage), #selector(AppDelegate.pasteImage), #selector(AppDelegate.save)]
    func allowed(_ action: Selector) -> Bool {
        delegate.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: ""))
    }
    delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: settings))
    check(model.settingsWindowActive && commands.allSatisfy { !allowed($0) }, "Settings disables background image commands")
    let copiedCount = clipboard.changeCount
    delegate.undo(); delegate.redo(); delegate.deleteMark(); delegate.copyImage(); delegate.pasteImage(); delegate.save()
    check(model.state.id == editedID && model.selectedID == mark.id, "Queued settings shortcuts cannot edit or replace the image")
    check(clipboard.changeCount == copiedCount, "Settings shortcuts preserve the existing clipboard")
    check(delegate.windowShouldClose(settings), "Closing Settings does not request saving a dirty editor")
    check(model.dirty && model.error == nil, "Closing Settings leaves editor state intact")

    delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: editor))
    check(!model.settingsWindowActive && allowed(#selector(AppDelegate.undo)), "Returning to the editor restores its command context")
    delegate.undo()
    check(model.state.marks.isEmpty && allowed(#selector(AppDelegate.redo)), "Editor undo still works")
    delegate.redo()
    check(model.state.id == editedID, "Editor redo restores the same image state")

    model.selectedID = mark.id
    model.isCapturing = true
    check(commands.allSatisfy { !allowed($0) } && !allowed(#selector(AppDelegate.showSettings)), "Capturing disables competing commands")
    delegate.undo(); delegate.redo(); delegate.deleteMark()
    check(model.state.id == editedID, "Queued commands cannot modify an in-flight capture")
    model.isCapturing = false

    let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
        styleMask: [.titled], backing: .buffered, defer: false)
    sheet.isReleasedWhenClosed = false
    settings.beginSheet(sheet)
    check(!delegate.canHandleActions && !delegate.windowShouldClose(settings), "Settings file dialogs block competing commands and closing")
    check(!allowed(#selector(AppDelegate.open)) && !allowed(#selector(AppDelegate.recentImages)), "A settings dialog cannot be hidden by an editor command")
    settings.endSheet(sheet)
    sheet.orderOut(nil)
    delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: settings))
    delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: sheet))
    check(model.settingsWindowActive, "Error sheets preserve the settings presentation context")
    delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: settings))
    check(!model.settingsWindowActive, "Closing Settings clears its presentation context")

    // A missing custom archive must not trap the user in the Settings window.
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let failingModel = EditorModel(history: HistoryStore(root: missing, requiresExistingRoot: true))
    failingModel.append(mark)
    let failingDelegate = AppDelegate(model: failingModel, updates: updates)
    failingDelegate.settingsWindow = settings
    check(failingDelegate.windowShouldClose(settings), "Settings can close when the archive drive is unavailable")
    check(failingModel.error == nil && failingModel.historyError != nil, "Closing Settings does not start a failing archive write")
    let previousPolicy = NSApp.activationPolicy()
    defer { NSApp.setActivationPolicy(previousPolicy); editor.orderOut(nil); settings.orderOut(nil) }
    settings.orderOut(nil)
    editor.orderOut(nil)
    delegate.presentInitialWindow(inBackground: true)
    check(!editor.isVisible && NSApp.activationPolicy() == .accessory,
        "Login startup leaves the editor and Dock hidden")
    delegate.showEditor()
    check(editor.isVisible && NSApp.activationPolicy() == .regular,
        "Opening the editor from background restores its window and Dock presence")
    editor.orderOut(nil)
    delegate.presentInitialWindow(inBackground: false)
    check(editor.isVisible, "A regular launch still opens the editor")
    // Real close notifications must hide the Dock without stopping global shortcuts.
    model.dirty = false
    check(shortcuts.set(CaptureKey(keyCode: UInt16(kVK_F20), modifiers: UInt32(cmdKey | controlKey | optionKey | shiftKey)), for: .area),
        "Dock lifecycle test uses an isolated global key")
    var captured: [CaptureMode] = []
    shortcuts.start { captured.append($0) }
    editor.performClose(nil)
    check(!editor.isVisible && NSApp.activationPolicy() == .accessory,
        "Closing the editor hides its Dock icon")
    check(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp),
        "Closing the last window leaves Capture Studio running")
    shortcuts.receive(.area, kind: UInt32(kEventHotKeyPressed))
    shortcuts.receive(.area, kind: UInt32(kEventHotKeyReleased))
    check(captured == [.area], "Global capture handlers still work after the editor closes")
    delegate.showEditor()
    check(editor.isVisible && NSApp.activationPolicy() == .regular,
        "Reopening a closed editor restores Dock presence")
    delegate.showSettings()
    editor.performClose(nil)
    check(settings.isVisible && NSApp.activationPolicy() == .regular,
        "Closing the editor keeps open Settings accessible from the Dock")
    settings.performClose(nil)
    check(!settings.isVisible && NSApp.activationPolicy() == .accessory,
        "Closing the last settings window returns to background")
    delegate.showSettings()
    check(settings.isVisible && !editor.isVisible && NSApp.activationPolicy() == .accessory,
        "Settings can open from the menu bar without opening the editor or Dock")
    settings.performClose(nil)
    delegate.showEditor()
    delegate.showSettings()
    delegate.prepareForCapture()
    check(!editor.isVisible && !settings.isVisible && NSApp.activationPolicy() == .accessory,
        "Capture hides editor, Settings and Dock together")
    check(!model.settingsWindowActive && delegate.canHandleActions,
        "Background capture leaves no stale Settings context")
    delegate.capturePreview.show(DemoImage.make(), screen: NSScreen.main) { delegate.showEditor() }
    check(!editor.isVisible && NSApp.activationPolicy() == .accessory,
        "Displaying a capture thumbnail does not restore the Dock")
    delegate.capturePreview.dismiss()
    delegate.showEditor()
    settings.orderFront(nil)
    settings.performClose(nil)
    check(editor.isVisible && NSApp.activationPolicy() == .regular,
        "Closing Settings while editing keeps the editor in the Dock")
    return count
}
