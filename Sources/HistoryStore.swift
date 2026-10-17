import AppKit

struct RecentImage: Codable, Identifiable {
    let id: UUID
    let revision: UUID
    let title: String
    let updatedAt: Date
    let width: Int
    let height: Int
    let bytes: Int
}

private struct StoredMark: Codable, Equatable {
    var id: UUID
    var tool: EditorTool
    var start: CGPoint
    var end: CGPoint
    var rgba: [CGFloat]
    var width: CGFloat
    var text: String
    var fontSize: CGFloat
    var blindStyle: BlindStyle
    var blockSize: CGFloat

    init(_ mark: Mark) {
        let color = mark.color.usingColorSpace(.sRGB) ?? .black
        id = mark.id; tool = mark.tool; start = mark.start; end = mark.end
        rgba = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        width = mark.width; text = mark.text; fontSize = mark.fontSize
        blindStyle = mark.blindStyle; blockSize = mark.blockSize
    }
    func decoded() throws -> Mark {
        let numbers = rgba + [start.x, start.y, end.x, end.y, width, fontSize, blockSize]
        guard rgba.count == 4, numbers.allSatisfy({ $0.isFinite && abs($0) < 1_000_000 }),
              rgba.allSatisfy({ (0...1).contains($0) }), (1...100).contains(width),
              (1...500).contains(fontSize), (8...96).contains(blockSize), text.count <= 1000,
              tool != .select && tool != .crop else { throw HistoryError.invalid }
        return Mark(id: id, tool: tool, start: start, end: end,
            color: NSColor(srgbRed: rgba[0], green: rgba[1], blue: rgba[2], alpha: rgba[3]),
            width: width, text: text, fontSize: fontSize, blindStyle: blindStyle, blockSize: blockSize)
    }
}

private struct StoredEdit: Codable, Equatable {
    let version: Int
    let marks: [StoredMark]
}
private struct HistoryIndex: Codable {
    var version = 1
    var items: [RecentImage]
}

enum HistoryError: LocalizedError {
    case invalid, missing, unavailable, destinationNotEmpty, nestedFolder, verification, editTooLarge
    var errorDescription: String? {
        switch self {
        case .invalid: return L("Could not read recent images. You can still save the current image as PNG.")
        case .missing: return L("The archived file for this image is missing.")
        case .unavailable: return L("Could not access the archive folder. Check its location or your external drive connection.")
        case .destinationNotEmpty: return L("Choose an empty folder or create one. Existing files will not be overwritten.")
        case .nestedFolder: return L("Choose a separate folder, outside the current archive and its parent folders.")
        case .verification: return L("Could not verify the moved files. Your original archive is unchanged.")
        case .editTooLarge: return L("There are too many annotations or too much text. Remove some annotations or save the image as PNG.")
        }
    }
}

// Every revision is immutable. Publishing the small index is the commit point;
// a failed write keeps the previous revision available.
// Mutable policy and filesystem transactions are serialized by lock.
final class HistoryStore: @unchecked Sendable {
    static let maximumMarks = 2000
    private static let maximumEditBytes = 4_000_000
    private struct SavedRevision {
        let item: RecentImage
        let image: CGImage
        let edit: StoredEdit
    }
    // Keep only the current image. This cache is protected by the same transaction lock
    // as writes, so an older in-flight save cannot cause a later undo to be skipped.
    private var savedRevision: SavedRevision?
    let root: URL
    let limit: Int?
    let byteLimit: Int?
    private var retentionDays: Int?
    private let requiresExistingRoot: Bool
    private let now: () -> Date
    private let trash: (URL) throws -> URL
    private let lock = NSRecursiveLock()
    private let files = FileManager.default
    private let writeIndex: (Data, URL) throws -> Void
    private var indexURL: URL { root.appendingPathComponent("index.json") }
    init(root: URL, limit: Int? = nil, byteLimit: Int? = nil, retentionDays: Int? = nil,
         requiresExistingRoot: Bool = false, now: @escaping () -> Date = Date.init,
         trash: @escaping (URL) throws -> URL = HistoryStore.moveToTrash,
         writeIndex: @escaping (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }) {
        self.root = root; self.limit = limit; self.byteLimit = byteLimit
        self.retentionDays = retentionDays.flatMap { $0 > 0 ? $0 : nil }
        self.requiresExistingRoot = requiresExistingRoot; self.now = now; self.trash = trash
        self.writeIndex = writeIndex
    }
    static var defaultRoot: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Capture Studio/Recent", isDirectory: true)
    }
    static func applicationStore(defaults: UserDefaults = .standard) -> HistoryStore {
        let settings = ArchivePreferences.load(from: defaults)
        return HistoryStore(root: settings.folder ?? defaultRoot, retentionDays: settings.retentionDays,
            requiresExistingRoot: settings.folder != nil)
    }
    static func moveToTrash(_ url: URL) throws -> URL {
        var result: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &result)
        guard let result else { throw HistoryError.missing }
        return result as URL
    }
    func setRetention(days: Int?) {
        lock.lock(); defer { lock.unlock() }
        retentionDays = days.flatMap { $0 > 0 ? $0 : nil }
    }
    private func checkAvailability() throws {
        if requiresExistingRoot && !files.fileExists(atPath: root.path) { throw HistoryError.unavailable }
    }
    func list() throws -> [RecentImage] {
        lock.lock(); defer { lock.unlock() }
        try checkAvailability()
        guard files.fileExists(atPath: indexURL.path) else {
            if requiresExistingRoot { throw HistoryError.invalid }
            return []
        }
        let data = try Data(contentsOf: indexURL)
        let index = try JSONDecoder().decode(HistoryIndex.self, from: data)
        guard index.version == 1,
              Set(index.items.map(\.id)).count == index.items.count,
              Set(index.items.map(\.revision)).count == index.items.count,
              index.items.allSatisfy({ $0.bytes >= 0 && $0.bytes <= 220_000_000 && $0.width > 0 && $0.height > 0
                  && Double($0.width) * Double($0.height) <= Double(ImageRenderer.maxPixels) }) else { throw HistoryError.invalid }
        return index.items
    }
    func folder(_ item: RecentImage) -> URL { root.appendingPathComponent(item.revision.uuidString, isDirectory: true) }
    func thumbnailURL(_ item: RecentImage) -> URL { folder(item).appendingPathComponent("thumbnail.png") }
    func read(_ item: RecentImage) throws -> EditState {
        lock.lock(); defer { lock.unlock() }
        let directory = folder(item)
        guard files.fileExists(atPath: directory.path) else { throw HistoryError.missing }
        let image = try ImageRenderer.load(directory.appendingPathComponent("image.png"))
        let data = try Data(contentsOf: directory.appendingPathComponent("edit.json"))
        guard data.count <= Self.maximumEditBytes else { throw HistoryError.invalid }
        let edit = try JSONDecoder().decode(StoredEdit.self, from: data)
        guard edit.version == 1, edit.marks.count <= Self.maximumMarks else { throw HistoryError.invalid }
        let state = EditState(image: image, marks: try edit.marks.map { try $0.decoded() })
        savedRevision = SavedRevision(item: item, image: image, edit: edit)
        return state
    }
    @discardableResult
    func save(id: UUID, title: String, state: EditState) throws -> [RecentImage] {
        lock.lock(); defer { lock.unlock() }
        let previous = try list()
        guard state.marks.count <= Self.maximumMarks else { throw HistoryError.editTooLarge }
        let stored = StoredEdit(version: 1, marks: state.marks.map(StoredMark.init))
        for mark in stored.marks { _ = try mark.decoded() }
        let edit = try JSONEncoder().encode(stored)
        guard edit.count <= Self.maximumEditBytes else { throw HistoryError.editTooLarge }
        let title = String(title.prefix(240))
        if let saved = savedRevision, saved.item.id == id, saved.item.title == title,
           saved.image === state.image, saved.edit == stored,
           previous.contains(where: { $0.id == id && $0.revision == saved.item.revision }),
           ["image.png", "edit.json", "thumbnail.png"].allSatisfy({ files.fileExists(atPath: folder(saved.item).appendingPathComponent($0).path) }) {
            // Viewing or closing is not an edit. Preserve its date and recent-list position.
            return try cleanExpired(protecting: id)
        }
        try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let revision = UUID()
        let directory = root.appendingPathComponent(revision.uuidString, isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var published = false
        defer { if !published { try? files.removeItem(at: directory) } }
        let image = try ImageRenderer.png(state.image)
        let preview = try ImageRenderer.thumbnail(ImageRenderer.render(state))
        guard image.count + edit.count + preview.count <= 220_000_000,
              Double(state.image.width) * Double(state.image.height) <= Double(ImageRenderer.maxPixels) else { throw HistoryError.invalid }
        try image.write(to: directory.appendingPathComponent("image.png"), options: .atomic)
        try edit.write(to: directory.appendingPathComponent("edit.json"), options: .atomic)
        try preview.write(to: directory.appendingPathComponent("thumbnail.png"), options: .atomic)
        let item = RecentImage(id: id, revision: revision, title: title, updatedAt: now(),
            width: state.image.width, height: state.image.height, bytes: image.count + edit.count + preview.count)
        var items = [item] + previous.filter { $0.id != id }
        while items.count > 1 && ((limit.map { items.count > $0 } ?? false)
            || (byteLimit.map { budget in items.reduce(0, { $0 + $1.bytes }) > budget } ?? false)) { items.removeLast() }
        items = retained(items, protecting: id)
        let keptIDs = Set(items.map(\.id))
        try publish(items, trashing: previous.filter { !keptIDs.contains($0.id) })
        published = true
        savedRevision = SavedRevision(item: item, image: state.image, edit: stored)
        // Reclaim only superseded revisions of this same image, not other saved photos.
        for old in previous where old.id == id { try? files.removeItem(at: folder(old)) }
        return items
    }
    private func retained(_ items: [RecentImage], protecting id: UUID?) -> [RecentImage] {
        guard let retentionDays else { return items }
        let cutoff = now().addingTimeInterval(-Double(retentionDays) * 86_400)
        return items.filter { $0.id == id || $0.updatedAt >= cutoff }
    }
    @discardableResult
    func cleanExpired(protecting id: UUID? = nil) throws -> [RecentImage] {
        lock.lock(); defer { lock.unlock() }
        let previous = try list()
        let next = retained(previous, protecting: id)
        if next.count != previous.count {
            let kept = Set(next.map(\.id))
            try publish(next, trashing: previous.filter { !kept.contains($0.id) })
        }
        return next
    }
    // Restore trashed files if publishing fails, so the previous index remains usable.
    private func publish(_ items: [RecentImage], trashing removed: [RecentImage]) throws {
        var moved: [(URL, URL)] = []
        do {
            for item in removed {
                let original = folder(item)
                if files.fileExists(atPath: original.path) { moved.append((original, try trash(original))) }
            }
            try publish(items)
        } catch {
            for (original, trashed) in moved.reversed() { try? files.moveItem(at: trashed, to: original) }
            throw error
        }
    }
    @discardableResult
    func remove(_ item: RecentImage) throws -> [RecentImage] {
        lock.lock(); defer { lock.unlock() }
        let previous = try list()
        let next = previous.filter { $0.id != item.id }
        guard next.count != previous.count else { return previous }
        // Recovery is available through the system Trash; the source photo is never touched.
        try publish(next, trashing: previous.filter { $0.id == item.id })
        return next
    }
    func relocated(to destination: URL) throws -> HistoryStore {
        lock.lock(); defer { lock.unlock() }
        let source = root.standardizedFileURL.resolvingSymlinksInPath()
        let target = destination.standardizedFileURL.resolvingSymlinksInPath()
        guard target.isFileURL else { throw HistoryError.unavailable }
        if source.path == target.path { return self }
        guard !target.path.hasPrefix(source.path + "/"), !source.path.hasPrefix(target.path + "/") else { throw HistoryError.nestedFolder }
        let items = try list()
        func isEmptyDestination() throws -> Bool {
            try files.contentsOfDirectory(atPath: target.path).allSatisfy { $0 == ".DS_Store" }
        }
        if files.fileExists(atPath: target.path), try !isEmptyDestination() { throw HistoryError.destinationNotEmpty }
        let stage = target.deletingLastPathComponent().appendingPathComponent(".CaptureStudio-Move-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? files.removeItem(at: stage) }
        for item in items {
            let copy = stage.appendingPathComponent(item.revision.uuidString, isDirectory: true)
            try files.createDirectory(at: copy, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            for name in ["image.png", "edit.json", "thumbnail.png"] {
                let original = folder(item).appendingPathComponent(name), output = copy.appendingPathComponent(name)
                let values = try original.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true else { throw HistoryError.verification }
                try files.copyItem(at: original, to: output)
                guard files.contentsEqual(atPath: original.path, andPath: output.path) else { throw HistoryError.verification }
            }
        }
        try writeIndex(JSONEncoder().encode(HistoryIndex(items: items)), stage.appendingPathComponent("index.json"))
        // Rename the verified archive into an empty destination on the same volume.
        if files.fileExists(atPath: target.path) {
            guard try isEmptyDestination() else { throw HistoryError.destinationNotEmpty }
            let metadata = target.appendingPathComponent(".DS_Store")
            if files.fileExists(atPath: metadata.path) { try files.copyItem(at: metadata, to: stage.appendingPathComponent(".DS_Store")) }
            try files.removeItem(at: target)
        }
        try files.moveItem(at: stage, to: target)
        let destination = HistoryStore(root: target, retentionDays: retentionDays, requiresExistingRoot: true, now: now, trash: trash)
        destination.savedRevision = savedRevision
        return destination
    }
    // Call only after preferences point at the verified new archive. Unknown files are left alone.
    func retire(afterMovingTo destination: HistoryStore) throws {
        lock.lock(); defer { lock.unlock() }
        guard root.standardizedFileURL.resolvingSymlinksInPath().path != destination.root.standardizedFileURL.resolvingSymlinksInPath().path,
              files.fileExists(atPath: root.path) else { return }
        let original = try list(), copied = try destination.list()
        guard Set(original.map(\.revision)) == Set(copied.map(\.revision)) else { throw HistoryError.verification }
        let managed = Set(original.map { $0.revision.uuidString }).union(["index.json", ".DS_Store"])
        guard Set(try files.contentsOfDirectory(atPath: root.path)).isSubset(of: managed) else { throw HistoryError.destinationNotEmpty }
        _ = try trash(root)
    }
    private func publish(_ items: [RecentImage]) throws {
        try writeIndex(JSONEncoder().encode(HistoryIndex(items: items)), indexURL)
    }
}
