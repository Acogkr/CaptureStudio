import AppKit

@MainActor
func runArchiveSettingsTests() throws -> Int {
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        guard (try? value()) == true else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        count += 1
    }
    let files = FileManager.default
    let temp = files.temporaryDirectory.appendingPathComponent("CaptureStudio-ArchiveTests-\(UUID().uuidString)")
    try files.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: temp) }
    let trashRoot = temp.appendingPathComponent("Trash")
    try files.createDirectory(at: trashRoot, withIntermediateDirectories: false)
    func trash(_ url: URL) throws -> URL {
        let destination = trashRoot.appendingPathComponent(UUID().uuidString)
        try files.moveItem(at: url, to: destination)
        return destination
    }
    let context = CGContext(data: nil, width: 16, height: 16, bitsPerComponent: 8, bytesPerRow: 64,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
    let photo = EditState(image: context.makeImage()!)
    var clock = Date(timeIntervalSince1970: 1_700_000_000)
    let start = clock
    let unlimited = HistoryStore(root: temp.appendingPathComponent("Unlimited"), now: { clock }, trash: trash)
    for index in 0..<105 { _ = try unlimited.save(id: UUID(), title: "Photo \(index)", state: photo) }
    check(try unlimited.list().count == 105, "Default archive retains more than both the old 20-photo cap and 100-item read limit")
    clock = start.addingTimeInterval(400 * 86_400)
    check(try unlimited.cleanExpired().count == 105, "Unconfigured cleanup keeps old images indefinitely")

    // Large byte metadata avoids allocating hundreds of MB just to test the removed capacity cap.
    let indexURL = unlimited.root.appendingPathComponent("index.json")
    var index = try JSONSerialization.jsonObject(with: Data(contentsOf: indexURL)) as! [String: Any]
    var entries = index["items"] as! [[String: Any]]
    for n in 0..<4 { entries[n]["bytes"] = 180_000_000 }
    index["items"] = entries
    try JSONSerialization.data(withJSONObject: index).write(to: indexURL)
    _ = try unlimited.save(id: UUID(), title: "Beyond old byte cap", state: photo)
    check(try unlimited.list().count == 106, "Default archive does not evict photos above the old 512 MB budget")

    clock = start
    let expiring = HistoryStore(root: temp.appendingPathComponent("Expiring"), now: { clock }, trash: trash)
    let oldID = UUID(), openID = UUID(), newID = UUID()
    _ = try expiring.save(id: oldID, title: "Old", state: photo)
    _ = try expiring.save(id: openID, title: "Open old photo", state: photo)
    clock = start.addingTimeInterval(31 * 86_400)
    _ = try expiring.save(id: newID, title: "New", state: photo)
    expiring.setRetention(days: 30)
    let survivors = try expiring.cleanExpired(protecting: openID)
    check(Set(survivors.map(\.id)) == Set([openID, newID]), "Explicit age cleanup preserves recent and currently open images")
    check(try files.contentsOfDirectory(atPath: trashRoot.path).count == 1, "Expired photo is recoverable in Trash")
    expiring.setRetention(days: nil)
    clock = start.addingTimeInterval(400 * 86_400)
    _ = try expiring.save(id: UUID(), title: "Cleanup disabled again", state: photo)
    check(try expiring.list().contains(where: { $0.id == openID }), "Disabling automatic deletion preserves old images on subsequent saves")
    let toRemove = try expiring.list().first!
    _ = try expiring.remove(toRemove)
    check(try !expiring.list().contains(where: { $0.id == toRemove.id }), "Manual removal remains available when automatic deletion is off")

    clock = start
    let rollback = HistoryStore(root: temp.appendingPathComponent("Rollback"), now: { clock }, trash: trash)
    let rollbackItems = try rollback.save(id: UUID(), title: "Preserve on error", state: photo)
    clock = start.addingTimeInterval(31 * 86_400)
    let failingIndex = HistoryStore(root: rollback.root, retentionDays: 30, now: { clock }, trash: trash,
        writeIndex: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
    do { _ = try failingIndex.cleanExpired(); check(false, "Cleanup index failure must be reported") }
    catch { check(true, "Cleanup index failure reported") }
    check(try rollback.list().count == 1 && rollback.read(rollbackItems[0]).image.width == 16,
        "Failed cleanup restores trashed data and preserves previous index")
    let failingTrash = HistoryStore(root: rollback.root, retentionDays: 30, now: { clock },
        trash: { _ in throw CocoaError(.fileWriteNoPermission) })
    do { _ = try failingTrash.cleanExpired(); check(false, "Trash failure must be reported") }
    catch { check(true, "Trash failure reported") }
    check(try rollback.list().count == 1, "Trash permission failure cannot silently remove an item from the archive")

    let source = HistoryStore(root: temp.appendingPathComponent("Source"), trash: trash)
    var edited = photo
    edited.marks = [Mark(tool: .text, start: .zero, end: .zero, color: .systemRed, width: 2, text: "보관")]
    let sourceItem = try source.save(id: UUID(), title: "Keep editable", state: edited)[0]
    let target = temp.appendingPathComponent("Destination")
    try files.createDirectory(at: target, withIntermediateDirectories: false)
    try Data("Finder metadata".utf8).write(to: target.appendingPathComponent(".DS_Store"))
    let migrated = try source.relocated(to: target)
    check(try String(contentsOf: target.appendingPathComponent(".DS_Store"), encoding: .utf8) == "Finder metadata",
        "An otherwise empty Finder folder is accepted and its metadata preserved")
    let migratedItem = try migrated.list()[0]
    check(migratedItem.id == sourceItem.id && migratedItem.revision == sourceItem.revision,
        "Folder migration preserves item identity and current selection")
    check(try migrated.read(migratedItem).marks.first?.text == "보관", "Folder migration preserves editable annotation data")
    check(files.contentsEqual(atPath: source.folder(sourceItem).appendingPathComponent("image.png").path,
        andPath: migrated.folder(migratedItem).appendingPathComponent("image.png").path), "Migrated image is byte-identical")
    check(files.fileExists(atPath: source.root.path), "Original archive is retained until preferences commit")
    try source.retire(afterMovingTo: migrated)
    check(!files.fileExists(atPath: source.root.path) && files.fileExists(atPath: migrated.root.path),
        "After commit the old archive moves to Trash while new archive stays available")
    check(try HistoryStore(root: target, requiresExistingRoot: true).read(migratedItem).marks.count == 1,
        "A fresh store reopens the migrated archive")
    check(try migrated.relocated(to: target) === migrated, "Choosing the current folder is a no-op")
    let nested = target.appendingPathComponent("Nested")
    do { _ = try migrated.relocated(to: nested); check(false, "Nested destination must fail") }
    catch { check(!files.fileExists(atPath: nested.path), "Nested destination rejected without touching source") }
    let occupied = temp.appendingPathComponent("Occupied")
    try files.createDirectory(at: occupied, withIntermediateDirectories: false)
    try Data("leave alone".utf8).write(to: occupied.appendingPathComponent("personal.txt"))
    do { _ = try migrated.relocated(to: occupied); check(false, "Occupied destination must fail") }
    catch { check(try String(contentsOf: occupied.appendingPathComponent("personal.txt"), encoding: .utf8) == "leave alone",
        "Existing destination files are never overwritten") }

    let failedTarget = temp.appendingPathComponent("FailedDestination")
    let brokenMigration = HistoryStore(root: migrated.root, writeIndex: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
    do { _ = try brokenMigration.relocated(to: failedTarget); check(false, "Migration publication failure must fail") }
    catch { check(!files.fileExists(atPath: failedTarget.path), "Failed migration does not publish an incomplete destination") }
    check(try migrated.read(migratedItem).marks.first?.text == "보관", "Failed migration keeps original archive readable")
    check(try !files.contentsOfDirectory(atPath: temp.path).contains(where: { $0.hasPrefix(".CaptureStudio-Move-") }),
        "Migration failure cleans its own staging folder")
    let missing = HistoryStore(root: temp.appendingPathComponent("Disconnected drive"), requiresExistingRoot: true)
    do { _ = try missing.save(id: UUID(), title: "Do not redirect", state: photo); check(false, "Missing custom archive must fail") }
    catch { check(!files.fileExists(atPath: missing.root.path), "Disconnected custom archive is not silently recreated") }

    let suite = "CaptureStudio-ArchiveTests-\(UUID().uuidString)"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let defaults = ArchivePreferences.load(from: preferences)
    check(!defaults.autoDelete && defaults.folder == nil, "First launch and upgrade default to automatic deletion off")
    let settings = ArchivePreferences(folderPath: migrated.root.path, autoDelete: true, days: 90)
    check(settings.save(to: preferences, synchronize: true) && ArchivePreferences.load(from: preferences) == settings,
        "Folder and retention preferences persist across reloads")
    let configured = HistoryStore.applicationStore(defaults: preferences)
    check(try configured.root == migrated.root && configured.list().count == 1, "Application opens the configured folder")
    var disabled = settings; disabled.autoDelete = false
    disabled.save(to: preferences)
    check(ArchivePreferences.load(from: preferences).retentionDays == nil && ArchivePreferences.load(from: preferences).days == 90,
        "Disabling cleanup remembers selected duration without applying it")

    let model = EditorModel(history: HistoryStore(root: configured.root, requiresExistingRoot: true, trash: trash), preferences: preferences)
    model.setAutoDelete(false)
    let modelDestination = temp.appendingPathComponent("ModelDestination")
    var moved: Bool?
    model.changeArchiveFolder(to: modelDestination) { moved = $0 }
    let deadline = Date().addingTimeInterval(8)
    while moved == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
    check(moved == true && model.history?.root == modelDestination && !model.isUpdatingArchive,
        "Model changes archive after flushing pending edits and finishes migration")
    check(ArchivePreferences.load(from: preferences).folder?.path == modelDestination.path && model.currentHistoryID == sourceItem.id,
        "Model migration persists destination and keeps the same open image")
    check(try model.history?.list().count == 1, "Migration does not create duplicate photos")
    return count
}
