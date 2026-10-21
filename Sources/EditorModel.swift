import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class EditorModel: ObservableObject {
    @Published var state: EditState
    @Published var tool: EditorTool = .arrow { didSet { if tool != oldValue { finishTextEditing() } } }
    @Published var color: NSColor = .systemRed { didSet { updateTextStyle() } }
    @Published var stroke: CGFloat = 4
    @Published var fontSize: CGFloat = 28 { didSet { updateTextStyle() } }
    @Published var blindStyle: BlindStyle = .solid
    @Published var blockSize: CGFloat = 24
    @Published var recents: [RecentImage] = []
    @Published var showHistory = false { didSet { if showHistory { finishTextEditing() } } }
    @Published var isSavingHistory = false
    @Published var historyError: String?
    @Published var currentHistoryID: UUID?
    @Published var selectedID: UUID?
    @Published var title = L("Sample Image")
    @Published var isExample = true
    @Published var dirty = false
    @Published var isCapturing = false
    @Published var error: String?
    @Published var toast: String?
    @Published var revision = 0
    @Published var showPermission = false
    @Published var settingsWindowActive = false
    @Published private(set) var editingText: Mark?
    private var textBaseline: EditState?
    private var past: [EditState] = []
    private var future: [EditState] = []
    private var savedID: UUID?
    private var toastTask: Task<Void, Never>?
    @Published private(set) var history: HistoryStore?
    @Published private(set) var archivePreferences: ArchivePreferences
    @Published private(set) var isUpdatingArchive = false
    @Published private(set) var archiveMessage: String?
    private let preferences: UserDefaults?
    private let clipboard: ImageClipboard?
    private lazy var manualClipboard = ImageClipboard()
    private let historyQueue = DispatchQueue(label: "CaptureStudio.history", qos: .utility)
    private var pendingSave: DispatchWorkItem?
    private var persistedID: UUID?
    private var historyGeneration = 0
    var window: NSWindow?
    var canUndo: Bool { !past.isEmpty || textHasChanges }
    var canRedo: Bool { !future.isEmpty && !textHasChanges }
    private var textHasChanges: Bool { textBaseline.map { $0.id != state.id } ?? false }
    var selectedMark: Mark? { state.marks.first { $0.id == selectedID } }
    var dimensions: String { "\(state.image.width) × \(state.image.height)" }

    var historyStatus: String {
        if historyError != nil { return L("Archive failed · Retry") }
        if isSavingHistory { return L("Archiving…") }
        return currentHistoryID == nil ? "" : L("Saved to Recents")
    }

    init(history: HistoryStore? = nil, clipboard: ImageClipboard? = nil, preferences: UserDefaults? = nil) {
        self.history = history
        self.preferences = preferences
        archivePreferences = preferences.map { ArchivePreferences.load(from: $0) } ?? ArchivePreferences()
        self.clipboard = clipboard
        let initial = EditState(image: DemoImage.make())
        state = initial
        savedID = initial.id
        clipboard?.onFailure = { [weak self] in
            self?.error = L("Could not copy your edits. Try the Copy button.")
        }
        if let history {
            do {
                recents = try history.list()
                // Skip an unreadable image without discarding other stored images.
                for item in recents {
                    if let restored = try? history.read(item) {
                        state = restored; title = item.title; isExample = false
                        currentHistoryID = item.id; persistedID = restored.id; savedID = restored.id
                        break
                    }
                }
                if !recents.isEmpty && currentHistoryID == nil { historyError = HistoryError.invalid.localizedDescription }
            } catch { historyError = error.localizedDescription }
        }
    }

    func commit(_ next: EditState) {
        finishTextEditing()
        past.append(state)
        if past.count > 30 { past.removeFirst() }
        future.removeAll()
        var updated = next
        updated.id = UUID()
        state = updated
        while past.count > 1 && historyBytes() > 400_000_000 { past.removeFirst() }
        dirty = state.id != savedID
        revision += 1
        scheduleHistory()
        copyEdit()
    }
    func undo() {
        finishTextEditing()
        guard let previous = past.popLast() else { return }
        future.append(state)
        state = previous
        selectedID = nil
        dirty = state.id != savedID
        revision += 1
        scheduleHistory()
        copyEdit()
    }
    private func historyBytes() -> Int {
        var images: Set<ObjectIdentifier> = []
        return (past + [state]).reduce(0) { total, snapshot in
            guard images.insert(ObjectIdentifier(snapshot.image)).inserted else { return total }
            return total + snapshot.image.bytesPerRow * snapshot.image.height
        }
    }
    func markUnsaved() { savedID = nil; dirty = true }
    func redo() {
        finishTextEditing()
        guard let next = future.popLast() else { return }
        past.append(state)
        state = next
        selectedID = nil
        dirty = state.id != savedID
        revision += 1
        scheduleHistory()
        copyEdit()
    }
    private func scheduleHistory() {
        guard let history else { return }
        let id = currentHistoryID ?? UUID()
        currentHistoryID = id
        pendingSave?.cancel()
        historyGeneration += 1
        let generation = historyGeneration
        isSavingHistory = true
        let snapshot = state, name = title
        let job = DispatchWorkItem { [weak self] in
            let result = Result { try history.save(id: id, title: name, state: snapshot) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.historyGeneration == generation else { return }
                switch result {
                case .success(let items):
                    self.recents = items
                    if self.state.id == snapshot.id && self.currentHistoryID == id {
                        self.persistedID = snapshot.id; self.isSavingHistory = false; self.historyError = nil
                    }
                case .failure(let error):
                    if self.state.id == snapshot.id { self.isSavingHistory = false; self.historyError = error.localizedDescription }
                }
            }
        }
        pendingSave = job
        historyQueue.asyncAfter(deadline: .now() + 0.45, execute: job)
    }
    @discardableResult
    func flushHistory() -> Bool {
        guard !isUpdatingArchive else { return false }
        finishTextEditing()
        historyGeneration += 1
        pendingSave?.cancel(); pendingSave = nil
        guard let history, let id = currentHistoryID else { return true }
        // Always serialize the latest state after any in-flight older write,
        // including undo back to a previously persisted revision.
        let snapshot = state, name = title
        do {
            let items = try historyQueue.sync { try history.save(id: id, title: name, state: snapshot) }
            recents = items; persistedID = snapshot.id; isSavingHistory = false; historyError = nil
            return true
        } catch {
            isSavingHistory = false; historyError = error.localizedDescription
            self.error = L("Could not archive the image. Save it and try again.\n\n") + error.localizedDescription
            return false
        }
    }
    func restoreRecent(_ item: RecentImage) {
        guard !isCapturing, !isUpdatingArchive, let history else { return }
        showHistory = false
        guard flushHistory() else { return }
        do {
            let latest = recents.first(where: { $0.id == item.id }) ?? item
            let restored = try history.read(latest)
            state = restored; title = item.title; isExample = false
            currentHistoryID = item.id; persistedID = restored.id; savedID = restored.id
            past.removeAll(); future.removeAll(); selectedID = nil; dirty = false; revision += 1
        } catch { self.error = error.localizedDescription }
    }
    func removeRecent(_ item: RecentImage) {
        guard let history, flushHistory() else { return }
        do {
            // A pending save may have replaced this item's revision.
            guard let latest = recents.first(where: { $0.id == item.id }) else { return }
            recents = try historyQueue.sync { try history.remove(latest) }
            if currentHistoryID == item.id {
                state = EditState(image: DemoImage.make()); title = L("Sample Image"); isExample = true
                currentHistoryID = nil; persistedID = nil; savedID = state.id; dirty = false
                selectedID = nil; past.removeAll(); future.removeAll(); revision += 1
            }
            notify(L("Archived copy moved to Trash."))
        } catch { self.error = error.localizedDescription }
    }
    func append(_ mark: Mark) {
        guard state.marks.count < HistoryStore.maximumMarks else { error = HistoryError.editTooLarge.localizedDescription; return }
        var next = state
        next.marks.append(mark)
        commit(next)
        selectedID = mark.id
    }
    func replace(_ mark: Mark) {
        guard let index = state.marks.firstIndex(where: { $0.id == mark.id }) else { return }
        var next = state
        next.marks[index] = mark
        commit(next)
    }
    func removeSelection() {
        guard let id = selectedID, state.marks.contains(where: { $0.id == id }) else { return }
        var next = state
        next.marks.removeAll { $0.id == id }
        commit(next)
        selectedID = nil
    }
    func crop(to rect: CGRect) {
        do { commit(try ImageRenderer.crop(state, to: rect)); selectedID = nil; tool = .select }
        catch { self.error = error.localizedDescription }
    }
    func beginTextEditing(at point: CGPoint, existing: Mark? = nil) {
        finishTextEditing()
        guard existing != nil || state.marks.count < HistoryStore.maximumMarks else {
            error = HistoryError.editTooLarge.localizedDescription; return
        }
        if let existing { color = existing.color; fontSize = existing.fontSize }
        let mark = existing ?? Mark(tool: .text, start: point, end: point, color: color, width: stroke, fontSize: fontSize)
        textBaseline = state
        selectedID = mark.id
        editingText = mark
    }
    func updateText(_ value: String) {
        guard var mark = editingText else { return }
        let value = String(value.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").prefix(1000))
        guard mark.text != value else { return }
        mark.text = value
        editingText = mark
        updateTextPreview()
    }
    private func updateTextStyle() {
        guard var mark = editingText, mark.color != color || mark.fontSize != fontSize else { return }
        mark.color = color; mark.fontSize = fontSize
        editingText = mark
        updateTextPreview()
    }
    private func updateTextPreview() {
        guard let baseline = textBaseline, let mark = editingText else { return }
        let wasChanged = textHasChanges
        let original = baseline.marks.first { $0.id == mark.id }
        let isEmpty = mark.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let changed = original.map { isEmpty || $0.text != mark.text || $0.color != mark.color || $0.fontSize != mark.fontSize } ?? !isEmpty
        guard changed || wasChanged else { return }
        var next = baseline
        if changed {
            if let index = next.marks.firstIndex(where: { $0.id == mark.id }) {
                if isEmpty { next.marks.remove(at: index) } else { next.marks[index] = mark }
            } else if !isEmpty { next.marks.append(mark) }
            next.id = UUID()
        }
        state = next
        dirty = state.id != savedID; revision += 1
        scheduleHistory()
        copyEdit()
    }
    func finishTextEditing(cancelled: Bool = false) {
        guard let baseline = textBaseline else { return }
        let changed = textHasChanges
        textBaseline = nil; editingText = nil
        if changed {
            if cancelled {
                state = baseline
                dirty = state.id != savedID; revision += 1
                scheduleHistory(); copyEdit()
            } else {
                past.append(baseline)
                if past.count > 30 { past.removeFirst() }
                while past.count > 1 && historyBytes() > 400_000_000 { past.removeFirst() }
                future.removeAll()
            }
        }
        if !state.marks.contains(where: { $0.id == selectedID }) { selectedID = nil }
    }
    func notify(_ message: String) {
        toastTask?.cancel()
        toast = message
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { self?.toast = nil }
        }
    }
    func confirmReplacement(_ action: @escaping () -> Void) {
        guard !isUpdatingArchive else { return }
        finishTextEditing()
        if history != nil { if flushHistory() { action() }; return }
        guard dirty, let window else { action(); return }
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = L("Save your edits?")
        alert.informativeText = L("Your edits will be lost if you don't save them.")
        alert.addButton(withTitle: L("Save"))
        alert.addButton(withTitle: L("Cancel"))
        alert.addButton(withTitle: L("Don't Save"))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn { self?.save(completion: action) }
            else if response == .alertThirdButtonReturn { action() }
        }
    }
    func load(_ image: CGImage, title: String) {
        finishTextEditing()
        state = EditState(image: image)
        self.title = title
        isExample = false
        dirty = false
        savedID = state.id
        selectedID = nil
        past.removeAll()
        future.removeAll()
        revision += 1
        currentHistoryID = history == nil ? nil : UUID()
        persistedID = nil
        scheduleHistory()
    }
    func importURL(_ url: URL) {
        guard !isCapturing else { return }
        do {
            let image = try ImageRenderer.load(url)
            confirmReplacement { self.load(image, title: url.deletingPathExtension().lastPathComponent) }
        } catch { self.error = error.localizedDescription }
    }
    func openImage() {
        guard !isCapturing, !isUpdatingArchive, let window else { return }
        finishTextEditing()
        do {
            let panel = NSOpenPanel()
            panel.title = L("Open Image")
            panel.prompt = L("Open")
            panel.allowedContentTypes = [.image]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.beginSheetModal(for: window) { response in
                guard response == .OK, let url = panel.url else { return }
                self.importURL(url)
            }
        }
    }
    func paste() {
        importPasteboard(.general)
    }
    func importPasteboard(_ pasteboard: NSPasteboard) {
        guard !isCapturing else { return }
        do {
            let (image, name) = try ImageInput.read(pasteboard)
            confirmReplacement { self.load(image, title: name); self.markUnsaved() }
        } catch { self.error = error.localizedDescription }
    }
    func makeBlindMark(start: CGPoint, end: CGPoint) -> Mark {
        Mark(tool: .redact, start: start, end: end, color: color, width: stroke, blindStyle: blindStyle, blockSize: blockSize)
    }
    func selectBlindStyle(_ style: BlindStyle) {
        blindStyle = style
        if var mark = selectedMark, mark.tool == .redact {
            mark.blindStyle = style
            replace(mark)
        }
    }
    func setBlockSize(_ size: CGFloat) {
        blockSize = size
        if var mark = selectedMark, mark.tool == .redact, mark.blindStyle == .mosaic {
            mark.blockSize = size
            replace(mark)
        }
    }
    private func copyEdit() {
        guard let clipboard else { return }
        if !clipboard.publish(state) { error = L("Could not copy your edits. Try the Copy button.") }
    }
    @discardableResult
    func copy(silently: Bool = false) -> Bool {
        finishTextEditing()
        guard (clipboard ?? manualClipboard).publish(state) else {
            error = L("Could not copy the image. Please try again.")
            return false
        }
        if !silently { notify(L("Image copied.")) }
        return true
    }
    @discardableResult
    func loadCapture(_ image: CGImage, title: String) -> Bool {
        load(image, title: title)
        markUnsaved()
        return copy(silently: true)
    }
    func finishClipboard() -> Bool {
        finishTextEditing()
        guard (clipboard ?? manualClipboard).finish() else {
            error = L("Could not keep the image on the clipboard. Copy it again before quitting.")
            return false
        }
        return true
    }
    func save(completion: (() -> Void)? = nil) {
        guard let window else { return }
        finishTextEditing()
        let panel = NSSavePanel()
        panel.title = L("Save Image")
        panel.prompt = L("Save")
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = (isExample ? "Capture" : title) + ".png"
        panel.canCreateDirectories = true
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            do {
                try ImageRenderer.png(ImageRenderer.render(self.state)).write(to: url, options: .atomic)
                self.dirty = false
                self.savedID = self.state.id
                self.notify(L("Image saved."))
                completion?()
            } catch { self.error = error.localizedDescription }
        }
    }

    func setAutoDelete(_ enabled: Bool) {
        guard !isUpdatingArchive, let history else { return }
        archivePreferences.autoDelete = enabled
        history.setRetention(days: archivePreferences.retentionDays)
        if let preferences { archivePreferences.save(to: preferences) }
        archiveMessage = nil
        if enabled { cleanExpiredHistory() }
    }
    func setRetentionDays(_ days: Int) {
        guard !isUpdatingArchive, ArchivePreferences.allowedDays.contains(days), let history else { return }
        archivePreferences.days = days
        history.setRetention(days: archivePreferences.retentionDays)
        if let preferences { archivePreferences.save(to: preferences) }
        archiveMessage = nil
        if archivePreferences.autoDelete { cleanExpiredHistory() }
    }
    func cleanExpiredHistory() {
        guard archivePreferences.autoDelete, !isUpdatingArchive, !isCapturing, let history else { return }
        let protectedID = currentHistoryID, generation = historyGeneration
        historyQueue.async { [weak self] in
            let result = Result { try history.cleanExpired(protecting: protectedID) }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.history === history, self.historyGeneration == generation, !self.isUpdatingArchive else { return }
                switch result {
                case .success(let items): self.recents = items
                case .failure(let error): self.archiveMessage = L("Could not finish automatic cleanup. ") + error.localizedDescription
                }
            }
        }
    }
    func revealArchive() {
        guard let history else { return }
        do {
            _ = try history.list()
            if !FileManager.default.fileExists(atPath: history.root.path) {
                try FileManager.default.createDirectory(at: history.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            NSWorkspace.shared.open(history.root)
        } catch { archiveMessage = error.localizedDescription }
    }
    func chooseArchiveFolder(in settingsWindow: NSWindow) {
        guard !isCapturing, !isUpdatingArchive, let history else { return }
        let panel = NSOpenPanel()
        panel.title = L("Archive Folder")
        panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.canCreateDirectories = true
        panel.prompt = L("Use This Folder")
        panel.message = L("Choose an empty folder or create one. Your images and edits will move with it.")
        panel.directoryURL = history.root.deletingLastPathComponent()
        panel.beginSheetModal(for: settingsWindow) { [weak self] response in
            guard response == .OK, let folder = panel.url else { return }
            self?.changeArchiveFolder(to: folder)
        }
    }
    func changeArchiveFolder(to folder: URL, completion: ((Bool) -> Void)? = nil) {
        guard !isCapturing, !isUpdatingArchive, let source = history else { completion?(false); return }
        if folder.standardizedFileURL.resolvingSymlinksInPath().path == source.root.standardizedFileURL.resolvingSymlinksInPath().path {
            archiveMessage = L("This is your current archive folder."); completion?(true); return
        }
        guard flushHistory() else { archiveMessage = L("The folder was not changed because your edits could not be archived."); completion?(false); return }
        isUpdatingArchive = true; archiveMessage = nil; showHistory = false
        historyGeneration += 1
        historyQueue.async { [weak self] in
            let result = Result { try source.relocated(to: folder) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { completion?(false); return }
                switch result {
                case .failure(let error):
                    self.isUpdatingArchive = false
                    self.archiveMessage = error.localizedDescription
                    completion?(false)
                case .success(let destination):
                    var next = self.archivePreferences
                    next.folderPath = destination.root.path
                    if let preferences = self.preferences, !next.save(to: preferences, synchronize: true) {
                        self.archivePreferences.save(to: preferences, synchronize: true)
                        self.isUpdatingArchive = false
                        self.archiveMessage = L("Could not save the new folder location. The original archive and the new copy are both intact.")
                        completion?(false); return
                    }
                    self.archivePreferences = next
                    self.history = destination
                    self.historyError = nil
                    // No old managed files are removed until the new archive is verified and its path persisted.
                    self.historyQueue.async {
                        let retired = Result { try source.retire(afterMovingTo: destination) }
                        DispatchQueue.main.async {
                            self.isUpdatingArchive = false
                            switch retired {
                            case .success: self.archiveMessage = L("Archive folder changed.")
                            case .failure: self.archiveMessage = L("Switched to the new folder. The old folder could not be cleaned up and is still in its original location.")
                            }
                            completion?(true)
                        }
                    }
                }
            }
        }
    }
}
