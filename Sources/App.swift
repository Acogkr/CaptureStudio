import AppKit
import SwiftUI

@main
enum CaptureStudioApp {
    @MainActor static func main() {
        if CommandLine.arguments == [CommandLine.arguments[0], "--screen-permission-probe"] {
            exit(CGPreflightScreenCaptureAccess() ? 0 : 2)
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--reopen-after-exit",
           let pid = pid_t(CommandLine.arguments[2]) {
            PermissionProcess.reopen(after: pid)
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--write-icon" {
            guard let tiff = AppIcon.make().tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
            do { try data.write(to: URL(fileURLWithPath: CommandLine.arguments[2])) } catch { exit(1) }
            return
        }
        let app = NSApplication.shared
        #if CAPTURE_TESTING
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--clipboard-producer" {
            let clipboard = ImageClipboard(pasteboard: NSPasteboard(name: .init(CommandLine.arguments[2])))
            guard clipboard.publish(EditState(image: DemoImage.make())), clipboard.finish() else { exit(1) }
            return
        }
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--session-lock-probe" {
            do {
                guard let lock = try SessionLock(directory: URL(fileURLWithPath: CommandLine.arguments[2])) else { exit(3) }
                withExtendedLifetime(lock) { exit(0) }
            } catch { exit(4) }
        }
        if CommandLine.arguments.contains("--test") { runTests(); return }
        #endif
        // Hold the process lock before EditorModel opens or writes the shared archive.
        let session: SessionLock
        do {
            guard let lock = try SessionLock(directory: HistoryStore.defaultRoot.deletingLastPathComponent()) else {
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name("CaptureStudioShowEditor"), object: nil, userInfo: nil, deliverImmediately: true)
                NSRunningApplication.runningApplications(withBundleIdentifier: "local.capturestudio.app")
                    .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }?
                    .activate(options: [.activateAllWindows])
                return
            }
            session = lock
        } catch {
            let alert = NSAlert(); alert.messageText = L("Unable to Complete")
            alert.informativeText = error.localizedDescription; alert.runModal(); return
        }
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime((session, delegate)) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuItemValidation {
    let model: EditorModel
    let captureService = CaptureService()
    let updates: UpdateChecker
    let capturePreview = CapturePreviewController()
    let shortcuts: CaptureShortcuts
    var window: NSWindow!
    var statusItem: NSStatusItem?
    var settingsWindow: NSWindow?
    private var cleanupTimer: Timer?
    private var closing = false
    private var pendingURLs: [URL]?
    private var workspaceObserver: NSObjectProtocol?
    private var permissionRestartPrepared = false
    private lazy var permissionRecovery = PermissionRecovery(
        currentAccess: { [weak self] in self?.captureService.hasPermission ?? false },
        ready: { [weak self] in
            self?.model.showPermission = false
            self?.model.notify(L("Screen capture is ready."))
        }, restart: { [weak self] in self?.restartAfterPermission() ?? true })
    init(model: EditorModel? = nil, updates: UpdateChecker? = nil, shortcuts: CaptureShortcuts? = nil) {
        self.model = model ?? EditorModel(history: HistoryStore.applicationStore(), clipboard: ImageClipboard(), preferences: .standard)
        self.updates = updates ?? UpdateChecker()
        self.shortcuts = shortcuts ?? CaptureShortcuts()
        super.init()
    }
    func applicationDidBecomeActive(_ notification: Notification) {
        captureService.refreshPermission(model: model)
        Task { @MainActor [weak self] in await self?.permissionRecovery.check() }
        updates.check()
    }
    func applicationDidResignActive(_ notification: Notification) { shortcuts.cancelRecording() }
    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { model.settingsWindowActive = true }
        else if (notification.object as? NSWindow) === window { model.settingsWindowActive = false }
        // A child sheet keeps its parent window's error-presentation context.
    }
    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { shortcuts.cancelRecording() }
    }
    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === settingsWindow { model.settingsWindowActive = false }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        captureService.needsPermission = { [weak self] in self?.permissionRecovery.begin() }
        captureService.lastExternalApplication = NSWorkspace.shared.frontmostApplication
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
                  app.activationPolicy == .regular else { return }
            let processID = app.processIdentifier
            Task { @MainActor [weak self] in
                guard let app = NSRunningApplication(processIdentifier: processID), !app.isTerminated else { return }
                self?.captureService.lastExternalApplication = app
            }
        }
        captureService.willCapture = { [weak self] in
            self?.capturePreview.dismiss()
            self?.settingsWindow?.orderOut(nil)
        }
        captureService.didCapture = { [weak self] image, screen in
            self?.capturePreview.show(image, screen: screen) { [weak self] in self?.showEditor() }
        }
        NSApp.applicationIconImage = AppIcon.make()
        buildMenus()
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 740), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Capture Studio"
        window.titlebarAppearsTransparent = true
        window.minSize = NSSize(width: 1000, height: 620)
        window.isReleasedWhenClosed = false
        window.delegate = self
        model.window = window
        window.contentView = NSHostingView(rootView: EditorView(model: model, updates: updates, shortcuts: shortcuts,
            cancelPermission: { [weak self] in self?.permissionRecovery.stop() },
            openPermissionSettings: { [weak self] in
                self?.permissionRecovery.begin()
                CaptureService.openPermissionSettings()
            }) { [weak self] mode in
            guard let self else { return }; self.captureService.start(mode, model: self.model)
        })
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "viewfinder", accessibilityDescription: "Capture Studio")
        buildStatusMenu()
        NotificationCenter.default.addObserver(self, selector: #selector(languageDidChange), name: Localization.changed, object: Localization.shared)
        NotificationCenter.default.addObserver(self, selector: #selector(systemLocaleDidChange), name: NSLocale.currentLocaleDidChangeNotification, object: nil)
        if let urls = pendingURLs { pendingURLs = nil; application(NSApp, open: urls) }
        shortcuts.didChange = { [weak self] in self?.buildMenus(); self?.buildStatusMenu() }
        shortcuts.start { [weak self] mode in
            guard let self, self.canHandleActions else { return }
            self.captureService.start(mode, model: self.model)
        }
        DistributedNotificationCenter.default().addObserver(self, selector: #selector(showEditor),
            name: Notification.Name("CaptureStudioShowEditor"), object: nil)
        model.cleanExpiredHistory()
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.model.cleanExpiredHistory() }
        }
        updates.start()
        if CommandLine.arguments.contains("--permission-recovered"), captureService.hasPermission {
            model.notify(L("Screen capture is ready."))
        }
    }
    private func buildStatusMenu() {
        let menu = NSMenu()
        menu.addItem(captureMenuItem(.area, #selector(captureArea)))
        menu.addItem(captureMenuItem(.window, #selector(captureWindow)))
        menu.addItem(captureMenuItem(.screen, #selector(captureScreen)))
        menu.addItem(.separator())
        menu.addItem(item(L("Open Editor"), #selector(showEditor)))
        menu.addItem(item(updates.actionTitle, #selector(checkForUpdates)))
        menu.addItem(item(L("Quit Capture Studio"), #selector(quit)))
        statusItem?.menu = menu
    }
    @objc private func systemLocaleDidChange() { Localization.shared.refreshSystemLanguage() }
    @objc private func languageDidChange() {
        buildMenus()
        buildStatusMenu()
        settingsWindow?.title = L("Settings")
        capturePreview.refreshLanguage()
    }
    func applicationWillTerminate(_ notification: Notification) {
        shortcuts.stop()
        DistributedNotificationCenter.default().removeObserver(self)
        updates.stop()
        cleanupTimer?.invalidate()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        NotificationCenter.default.removeObserver(self)
    }
    private func item(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self; item.keyEquivalentModifierMask = modifiers
        return item
    }
    private func captureMenuItem(_ mode: CaptureMode, _ action: Selector) -> NSMenuItem {
        let key = shortcuts.bindings[mode]
        return item(mode.title, action, key: key?.menuEquivalent ?? "", modifiers: key?.flags ?? [])
    }
    private func buildMenus() {
        let main = NSMenu()
        func section(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: title); item.submenu = menu; main.addItem(item); return menu
        }
        let app = section("Capture Studio")
        app.addItem(item(L("About Capture Studio"), #selector(about)))
        app.addItem(item(updates.actionTitle, #selector(checkForUpdates)))
        app.addItem(.separator())
        app.addItem(item(L("Settings…"), #selector(showSettings), key: ","))
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: L("Hide Capture Studio"), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        app.addItem(item(L("Quit Capture Studio"), #selector(quit), key: "q"))
        let file = section(L("File"))
        file.addItem(item(L("Open Image…"), #selector(open), key: "o"))
        file.addItem(.separator())
        file.addItem(captureMenuItem(.area, #selector(captureArea)))
        file.addItem(captureMenuItem(.window, #selector(captureWindow)))
        file.addItem(captureMenuItem(.screen, #selector(captureScreen)))
        file.addItem(.separator())
        file.addItem(item(L("Save…"), #selector(save), key: "s"))
        file.addItem(item(L("Recent Images"), #selector(recentImages), key: "r", modifiers: [.command, .shift]))
        file.addItem(NSMenuItem(title: L("Close"), action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        let edit = section(L("Edit"))
        edit.addItem(item(L("Undo"), #selector(undo), key: "z"))
        edit.addItem(item(L("Redo"), #selector(redo), key: "z", modifiers: [.command, .shift]))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: L("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(item(L("Copy Image"), #selector(copyImage), key: "c"))
        edit.addItem(item(L("Paste Image"), #selector(pasteImage), key: "v"))
        edit.addItem(NSMenuItem(title: L("Select All"), action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        edit.addItem(item(L("Delete Annotation"), #selector(deleteMark)))
        let windows = section(L("Window"))
        windows.addItem(item(L("Open Editor"), #selector(showEditor)))
        windows.addItem(NSMenuItem(title: L("Minimize"), action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        NSApp.windowsMenu = windows; NSApp.mainMenu = main
    }
    var canHandleActions: Bool {
        shortcuts.recording == nil && !model.isCapturing && !model.isUpdatingArchive && window?.attachedSheet == nil
            && settingsWindow?.attachedSheet == nil && NSApp.modalWindow == nil
    }
    var canHandleEditorActions: Bool { canHandleActions && !model.settingsWindowActive }
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if item.action == #selector(checkForUpdates) {
            item.title = updates.actionTitle
            return !updates.isChecking && canHandleActions
        }
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            if item.action == #selector(copyImage) { return text.selectedRange().length > 0 }
            if item.action == #selector(pasteImage) { return text.isEditable }
            if item.action == #selector(undo) { return text.isEditable && text.undoManager?.canUndo == true }
            if item.action == #selector(redo) { return text.isEditable && text.undoManager?.canRedo == true }
        }
        if item.action == #selector(quit) || item.action == #selector(about) { return true }
        guard canHandleActions else { return false }
        if item.action == #selector(undo) { return canHandleEditorActions && model.canUndo }
        if item.action == #selector(redo) { return canHandleEditorActions && model.canRedo }
        if item.action == #selector(deleteMark) { return canHandleEditorActions && model.selectedID != nil }
        if item.action == #selector(save) || item.action == #selector(copyImage) || item.action == #selector(pasteImage) {
            return canHandleEditorActions
        }
        return true
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if sender === settingsWindow { shortcuts.cancelRecording() }
        guard canHandleActions else { return false }
        if sender === settingsWindow { return true }
        if model.history != nil { return model.flushHistory() || !model.dirty }
        if closing || !model.dirty { closing = false; return true }
        model.confirmReplacement { [weak self] in self?.closing = true; sender.close() }
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if permissionRestartPrepared { captureService.stop(); return .terminateNow }
        guard !model.isUpdatingArchive, settingsWindow?.attachedSheet == nil else { return .terminateCancel }
        // The informational permission sheet must not block macOS Quit & Reopen.
        if window?.attachedSheet != nil && !model.showPermission { return .terminateCancel }
        guard model.finishClipboard() else { showEditor(); return .terminateCancel }
        if model.history != nil {
            guard model.flushHistory() || !model.dirty else { return .terminateCancel }
            captureService.stop()
            return .terminateNow
        }
        if model.dirty {
            showEditor()
            model.confirmReplacement { [weak self] in self?.model.dirty = false; NSApp.terminate(nil) }
            return .terminateCancel
        }
        captureService.stop(); return .terminateNow
    }
    /// Returning false leaves recovery pending until a modal operation finishes.
    private func restartAfterPermission() -> Bool {
        guard !model.isCapturing, !model.isUpdatingArchive, model.error == nil else { return false }
        if model.showPermission { model.showPermission = false; return false }
        guard NSApp.modalWindow == nil, NSApp.windows.allSatisfy({ $0.attachedSheet == nil }) else { return false }
        guard prepareForPermissionRestart() else { return true }
        do {
            try PermissionProcess.scheduleRestart()
            permissionRestartPrepared = true
            NSApp.terminate(nil)
        } catch {
            model.error = L("Could not restart Capture Studio. Your edits are saved. Reopen the app to continue.")
        }
        return true
    }
    func prepareForPermissionRestart() -> Bool {
        guard !model.isCapturing, !model.isUpdatingArchive,
              model.history != nil || !model.dirty else { return false }
        // Commit inline text before completing its final clipboard representation.
        guard model.flushHistory(), model.finishClipboard() else { return false }
        return true
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showEditor(); return true }
    func application(_ application: NSApplication, open urls: [URL]) {
        guard window != nil else { pendingURLs = urls; return }
        guard urls.count == 1 else { model.error = InputError.oneImage.localizedDescription; return }
        showEditor()
        model.importURL(urls[0])
    }
    @objc func showEditor() {
        shortcuts.cancelRecording()
        capturePreview.dismiss()
        model.settingsWindowActive = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func showSettings() {
        guard canHandleActions else { return }
        model.finishTextEditing()
        model.showHistory = false
        if settingsWindow == nil {
            let panel = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: min(660, (NSScreen.main?.visibleFrame.height ?? 760) - 100)),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            panel.title = L("Settings")
            panel.isReleasedWhenClosed = false
            panel.delegate = self
            panel.contentView = NSHostingView(rootView: ArchiveSettingsView(model: model, updates: updates, shortcuts: shortcuts) { [weak self] in
                guard let self, let panel = self.settingsWindow else { return }
                self.model.chooseArchiveFolder(in: panel)
            })
            panel.center()
            settingsWindow = panel
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc func captureArea() { guard canHandleActions else { return }; captureService.start(.area, model: model) }
    @objc func checkForUpdates() {
        guard !model.isCapturing, !model.isUpdatingArchive, window?.attachedSheet == nil,
              settingsWindow?.attachedSheet == nil, NSApp.modalWindow == nil else { return }
        if updates.availableRelease == nil {
            showSettings(); updates.check(manual: true)
        } else if !updates.openRelease() { showSettings() }
    }
    @objc func captureWindow() { guard canHandleActions else { return }; captureService.start(.window, model: model) }
    @objc func captureScreen() { guard canHandleActions else { return }; captureService.start(.screen, model: model) }
    @objc func open() { guard canHandleActions else { return }; showEditor(); model.openImage() }
    @objc func save() { guard canHandleEditorActions else { return }; model.save() }
    @objc func recentImages() { guard canHandleActions else { return }; showEditor(); model.showHistory.toggle() }
    @objc func undo() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            if text.isEditable { text.undoManager?.undo() }
        } else if canHandleEditorActions { model.undo() }
    }
    @objc func redo() {
        if let text = NSApp.keyWindow?.firstResponder as? NSTextView {
            if text.isEditable { text.undoManager?.redo() }
        } else if canHandleEditorActions { model.redo() }
    }
    @objc func copyImage() {
        if let field = NSApp.keyWindow?.firstResponder as? NSTextView { field.copy(nil) }
        else if canHandleEditorActions { model.copy() }
    }
    @objc func pasteImage() {
        if let field = NSApp.keyWindow?.firstResponder as? NSTextView {
            if field.isEditable { field.paste(nil) }
        } else if canHandleEditorActions { model.paste() }
    }
    @objc func deleteMark() { guard canHandleEditorActions else { return }; model.removeSelection() }
    @objc func quit() { NSApp.terminate(nil) }
    @objc func about() {
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Capture Studio", .applicationVersion: AppVersion.current, .version: AppVersion.build, .credits: NSAttributedString(string: L("Capture, annotate, and copy."))])
    }
}
