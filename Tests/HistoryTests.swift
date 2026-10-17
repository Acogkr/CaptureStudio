import AppKit

@MainActor
func runHistoryTests() throws -> Int {
    var count = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) {
        guard (try? value()) == true else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        count += 1
    }
    func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> NSColor {
        NSBitmapImageRep(cgImage: image).colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
    }
    let temp = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureStudio-HistoryTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temp) }
    func testTrash(_ url: URL) throws -> URL {
        let destination = temp.appendingPathComponent("Trashed-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }
    let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 512,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for y in 0..<128 {
        for x in 0..<128 {
            context.setFillColor(CGColor(red: CGFloat((x * 17 + y * 43) % 256) / 255,
                green: CGFloat((x * 31 + y * 19) % 256) / 255, blue: CGFloat((x * 47 + y * 7) % 256) / 255, alpha: 1))
            context.fill(CGRect(x: x, y: y, width: 1, height: 1))
        }
    }
    let source = context.makeImage()!
    let mosaic = Mark(tool: .redact, start: CGPoint(x: 16, y: 16), end: CGPoint(x: 112, y: 112), color: .red, width: 4, blindStyle: .mosaic, blockSize: 24)
    let edited = EditState(image: source, marks: [mosaic])
    let output = try ImageRenderer.render(edited)
    let a = pixel(output, 20, 20), b = pixel(output, 30, 30)
    check(abs(a.redComponent - b.redComponent) < 0.01 && abs(a.greenComponent - b.greenComponent) < 0.01, "Mosaic produces flat blocks")
    check(abs(pixel(source, 20, 20).redComponent - a.redComponent) > 0.01, "Mosaic changes source pixels")
    check(abs(pixel(source, 4, 4).redComponent - pixel(output, 4, 4).redComponent) < 0.01, "Mosaic preserves outside pixels")
    var solid = mosaic
    solid.id = UUID(); solid.blindStyle = .solid
    let overlapping = try ImageRenderer.render(EditState(image: source, marks: [solid, mosaic]))
    check(pixel(overlapping, 50, 50).redComponent < 0.15 && pixel(overlapping, 50, 50).alphaComponent == 1, "Mosaic over solid cannot expose original")
    let png = try ImageRenderer.png(output)
    let decoded = try ImageRenderer.load(png)
    check(abs(pixel(decoded, 20, 20).redComponent - a.redComponent) < 0.01, "Mosaic survives PNG export")

    let original = temp.appendingPathComponent("Photo.png")
    let originalData = try ImageRenderer.png(source)
    try originalData.write(to: original)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.writeObjects([original as NSURL])
    let (fromFile, title) = try ImageInput.read(board)
    check(fromFile.width == 128 && title == "Photo", "Finder file clipboard opens actual photo")
    board.clearContents(); board.setData(png, forType: .png)
    let (fromPNG, _) = try ImageInput.read(board)
    check(fromPNG.width == 128 && abs(pixel(fromPNG, 20, 20).redComponent - a.redComponent) < 0.01, "Image clipboard preserves pixels")
    board.clearContents(); board.setString("text only", forType: .string)
    do { _ = try ImageInput.read(board); check(false, "Text clipboard rejected") } catch { check(true, "Text clipboard rejected") }
    board.clearContents(); board.writeObjects([original as NSURL, temp.appendingPathComponent("Other.png") as NSURL])
    do { _ = try ImageInput.read(board); check(false, "Multiple pasted files rejected") } catch { check(true, "Multiple pasted files rejected") }
    do { _ = try ImageRenderer.load(Data("not an image".utf8)); check(false, "Invalid image rejected") } catch { check(true, "Invalid image rejected") }

    let root = temp.appendingPathComponent("History")
    let store = HistoryStore(root: root, limit: 2, trash: testTrash)
    let id = UUID()
    let first = try store.save(id: id, title: "First photo", state: edited)[0]
    let rebooted = HistoryStore(root: root, limit: 2)
    let items = try rebooted.list()
    check(items.count == 1 && items[0].id == id, "History survives restart")
    let restored = try rebooted.read(items[0])
    check(restored.marks.count == 1 && restored.marks[0].blindStyle == .mosaic && restored.marks[0].blockSize == 24, "Editable mosaic settings restored")
    check(abs(pixel(try ImageRenderer.render(restored), 20, 20).redComponent - a.redComponent) < 0.01, "Restored edit renders identically")
    check(FileManager.default.fileExists(atPath: store.thumbnailURL(first).path), "Edited thumbnail stored")
    var updated = edited; updated.marks = [solid]
    let secondRevision = try store.save(id: id, title: "First photo edited", state: updated)[0]
    check(try secondRevision.revision != first.revision && store.list().count == 1, "Editing updates one recent entry")
    check(!FileManager.default.fileExists(atPath: store.folder(first).path), "Obsolete revision reclaimed after commit")
    let savedIndex = try Data(contentsOf: root.appendingPathComponent("index.json"))
    let failing = HistoryStore(root: root, writeIndex: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
    do { _ = try failing.save(id: id, title: "Must not replace", state: edited); check(false, "Index commit failure reported") }
    catch { check(true, "Index commit failure reported") }
    check(try Data(contentsOf: root.appendingPathComponent("index.json")) == savedIndex, "Failed save preserves previous index")
    check(try store.read(secondRevision).marks[0].blindStyle == .solid, "Failed save preserves previous edit")
    let contents = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    check(contents.count == 2, "Failed revision cleaned without leaking files")
    _ = try store.save(id: UUID(), title: "Second", state: edited)
    let bounded = try store.save(id: UUID(), title: "Third", state: edited)
    check(bounded.count == 2 && !bounded.contains(where: { $0.id == id }), "Recent count bounded, oldest evicted")
    let byteStore = HistoryStore(root: temp.appendingPathComponent("Bytes"), byteLimit: first.bytes + 10, trash: testTrash)
    _ = try byteStore.save(id: UUID(), title: "One", state: edited)
    check(try byteStore.save(id: UUID(), title: "Two", state: edited).count == 1, "Recent byte budget bounded")
    check(try Data(contentsOf: original) == originalData, "Source photo never modified")

    let modelStore = HistoryStore(root: temp.appendingPathComponent("Model"))
    let model = EditorModel(history: modelStore)
    model.load(source, title: "Editable photo")
    model.append(mosaic)
    check(model.flushHistory(), "Current edit flushed before leaving")
    let priorItem = model.recents[0]
    model.append(solid)
    model.restoreRecent(priorItem)
    check(model.error == nil && model.state.marks.count == 2, "Opening current recent item resolves newly saved revision")
    model.importURL(original)
    check(model.flushHistory() && model.recents.count == 2, "Switching images preserves both documents")
    let restart = EditorModel(history: modelStore)
    check(restart.title == "Photo" && restart.recents.count == 2, "App restart opens latest saved image")
    let old = restart.recents.first { $0.title == "Editable photo" }!
    restart.restoreRecent(old)
    check(restart.state.marks.count == 2, "Older document retains editable marks")
    restart.selectedID = restart.state.marks[0].id
    restart.removeSelection()
    check(restart.flushHistory(), "Edits to restored documents persisted")
    let afterEdit = EditorModel(history: modelStore)
    check(afterEdit.state.marks.count == 1, "Edited history survives another restart")
    let broken = HistoryStore(root: temp.appendingPathComponent("Failed"), writeIndex: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })
    let protected = EditorModel(history: broken)
    protected.load(source, title: "Keep me")
    protected.append(solid)
    var switched = false
    protected.confirmReplacement { switched = true }
    check(!switched && protected.state.marks.count == 1 && protected.historyError != nil, "Write failure blocks data-losing switch")
    // Atomic saves settle before these private test directories are removed.
    check(try modelStore.list().count == 2, "No accidental duplicate history entries")
    let writeStarted = DispatchSemaphore(value: 0), releaseWrite = DispatchSemaphore(value: 0)
    var writes = 0
    let raceStore = HistoryStore(root: temp.appendingPathComponent("Race"), writeIndex: { data, url in
        writes += 1
        if writes == 2 {
            writeStarted.signal()
            _ = releaseWrite.wait(timeout: .now() + 4)
        }
        try data.write(to: url, options: .atomic)
    })
    let racing = EditorModel(history: raceStore)
    racing.load(source, title: "Undo while saving")
    check(racing.flushHistory(), "Initial race-test snapshot saved")
    racing.append(solid)
    check(writeStarted.wait(timeout: .now() + 3) == .success, "Background autosave started")
    racing.undo()
    releaseWrite.signal()
    check(racing.flushHistory(), "Latest undo state saved after older in-flight write")
    let raceRestored = EditorModel(history: raceStore)
    check(raceRestored.state.marks.isEmpty, "Older background save cannot resurrect undone edits")

    var archiveTime = Date(timeIntervalSince1970: 1_700_000_000)
    let viewingStore = HistoryStore(root: temp.appendingPathComponent("Viewing"), now: { archiveTime }, trash: testTrash)
    let older = try viewingStore.save(id: UUID(), title: "Older", state: edited)[0]
    archiveTime = archiveTime.addingTimeInterval(86_400)
    let newer = try viewingStore.save(id: UUID(), title: "Newer", state: edited)[0]
    let viewing = EditorModel(history: viewingStore)
    let indexBeforeViewing = try Data(contentsOf: viewingStore.root.appendingPathComponent("index.json"))
    archiveTime = archiveTime.addingTimeInterval(3600)
    check(viewing.flushHistory(), "Unchanged document can be flushed")
    check(try Data(contentsOf: viewingStore.root.appendingPathComponent("index.json")) == indexBeforeViewing,
        "Viewing and closing must not rewrite the archive or reset last-edit time")
    viewing.restoreRecent(older)
    check(viewing.flushHistory(), "Viewed older document can be closed")
    check(try viewingStore.list().map(\.id) == [newer.id, older.id] && viewingStore.list().last?.updatedAt == older.updatedAt,
        "Browsing older photos must not reorder history or extend retention")
    viewing.append(solid)
    check(viewing.flushHistory(), "Real edit is saved after a read-only visit")
    check(try viewingStore.list().first?.id == older.id && viewingStore.list().first?.updatedAt == archiveTime,
        "Actual editing updates last-edit time and recent order")
    let movedStore = try viewingStore.relocated(to: temp.appendingPathComponent("ViewedMove"))
    archiveTime = archiveTime.addingTimeInterval(3600)
    let beforeMoveFlush = try Data(contentsOf: movedStore.root.appendingPathComponent("index.json"))
    _ = try movedStore.save(id: older.id, title: viewing.title, state: viewing.state)
    check(try Data(contentsOf: movedStore.root.appendingPathComponent("index.json")) == beforeMoveFlush,
        "Changing archive location alone does not reset last-edit time")
    let cold = EditorModel(history: HistoryStore(root: movedStore.root))
    check(try cold.flushHistory() && Data(contentsOf: movedStore.root.appendingPathComponent("index.json")) == beforeMoveFlush,
        "Restarting and closing does not rewrite an unchanged document")

    let guarded = HistoryStore(root: temp.appendingPathComponent("Readable"))
    let guardedID = UUID()
    _ = try guarded.save(id: guardedID, title: "Readable", state: edited)
    let readableIndex = try Data(contentsOf: guarded.root.appendingPathComponent("index.json"))
    let excessMarks = EditState(image: source, marks: (0..<2001).map { _ in
        Mark(tool: .text, start: .zero, end: .zero, color: .black, width: 2, text: "x")
    })
    do { _ = try guarded.save(id: guardedID, title: "Too many", state: excessMarks); check(false, "Unreadable annotation count must not be published") }
    catch { check(true, "Unreadable annotation count rejected") }
    let excessText = EditState(image: source, marks: (0..<1600).map { _ in
        Mark(tool: .text, start: .zero, end: .zero, color: .black, width: 2, text: String(repeating: "가", count: 1000))
    })
    do { _ = try guarded.save(id: guardedID, title: "Too large", state: excessText); check(false, "Unreadable edit metadata must not be published") }
    catch { check(true, "Unreadable metadata size rejected") }
    check(try Data(contentsOf: guarded.root.appendingPathComponent("index.json")) == readableIndex && guarded.read(guarded.list()[0]).marks.count == 1,
        "Rejected large edits preserve the last readable archive")
    let capped = EditorModel()
    capped.state = EditState(image: source, marks: Array(excessMarks.marks.prefix(2000)))
    capped.append(solid)
    check(capped.state.marks.count == 2000 && capped.error != nil, "Canvas cannot add more annotations than the archive can restore")
    capped.beginTextEditing(at: .zero)
    check(capped.editingText == nil, "New text cannot bypass annotation limit")
    capped.beginTextEditing(at: .zero, existing: capped.state.marks[0])
    check(capped.editingText != nil, "Existing text remains editable at the annotation limit")
    capped.finishTextEditing()
    let jpegURL = temp.appendingPathComponent("Rotated.jpg")
    let jpegSource = source.cropping(to: CGRect(x: 0, y: 0, width: 64, height: 32))!
    let destination = CGImageDestinationCreateWithURL(jpegURL as CFURL, "public.jpeg" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, jpegSource, [kCGImagePropertyOrientation: 6] as CFDictionary)
    check(CGImageDestinationFinalize(destination), "JPEG test fixture encoded")
    let rotated = try ImageRenderer.load(jpegURL)
    check(rotated.width == 32 && rotated.height == 64, "Photo EXIF orientation applied on import")
    return count
}
