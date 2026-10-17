import AppKit

@MainActor
func runPermissionRecoveryTests() throws -> Int {
    var count = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: "PermissionRecoveryTests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]) }
        count += 1
    }
    func poll(_ recovery: PermissionRecovery) {
        var finished = false
        Task { @MainActor in await recovery.check(); finished = true }
        while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    }
    var current = false, fresh: Bool? = false, canRestart = true
    var ready = 0, restarted = 0, probes = 0
    var date = Date()
    let recovery = PermissionRecovery(currentAccess: { current }, freshAccess: { probes += 1; return fresh },
        now: { date }, ready: { ready += 1 }, restart: {
            guard canRestart else { return false }
            restarted += 1; return true
        })
    poll(recovery)
    try check(probes == 0, "No background permission check before a denied capture")
    recovery.begin(automatically: false)
    poll(recovery); poll(recovery)
    try check(recovery.isWaiting && restarted == 0 && ready == 0,
        "Permission still denied never causes a restart loop")
    fresh = nil; poll(recovery)
    try check(recovery.isWaiting && restarted == 0, "A failed probe is not treated as permission")
    fresh = true; canRestart = false; poll(recovery)
    try check(recovery.isWaiting && restarted == 0, "An active modal operation defers the restart")
    canRestart = true; poll(recovery); poll(recovery)
    try check(restarted == 1 && ready == 0 && !recovery.isWaiting, "A stale process restarts once after a verified grant")
    recovery.begin(automatically: false)
    current = true
    let earlier = probes
    poll(recovery)
    try check(ready == 1 && restarted == 1 && probes == earlier, "Live permission takes effect without restarting")
    current = false; fresh = false
    recovery.begin(automatically: false)
    recovery.stop(); poll(recovery)
    try check(!recovery.isWaiting && probes == earlier, "Later cancels permission recovery")
    recovery.begin(automatically: false)
    date = date.addingTimeInterval(601); poll(recovery)
    try check(!recovery.isWaiting && restarted == 1, "Abandoned setup expires instead of polling indefinitely")
    recovery.begin(automatically: false)
    date = date.addingTimeInterval(590)
    recovery.begin(automatically: false)
    date = date.addingTimeInterval(20)
    poll(recovery)
    try check(recovery.isWaiting, "Opening settings renews recovery even near the old timeout")
    current = true; poll(recovery)
    try check(!recovery.isWaiting && ready == 2, "Permission after renewed setup is applied without another capture attempt")
    current = false

    var pending: CheckedContinuation<Bool?, Never>?
    var completed = false, staleRestart = 0
    let delayed = PermissionRecovery(currentAccess: { false }, freshAccess: {
        await withCheckedContinuation { pending = $0 }
    }, ready: {}, restart: { staleRestart += 1; return true })
    delayed.begin(automatically: false)
    Task { @MainActor in await delayed.check(); completed = true }
    while pending == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    poll(delayed)
    delayed.stop()
    pending?.resume(returning: true)
    while !completed { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    try check(staleRestart == 0, "Cancelled async checks cannot later restart the app")

    var pendingRenewal: CheckedContinuation<Bool?, Never>?
    var renewalFinished = false, renewalRestarts = 0
    let renewal = PermissionRecovery(currentAccess: { false }, freshAccess: {
        await withCheckedContinuation { pendingRenewal = $0 }
    }, now: { date }, ready: {}, restart: { renewalRestarts += 1; return true })
    renewal.begin(automatically: false)
    Task { @MainActor in await renewal.check(); renewalFinished = true }
    while pendingRenewal == nil { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    date = date.addingTimeInterval(590)
    renewal.begin(automatically: false)
    date = date.addingTimeInterval(20)
    pendingRenewal?.resume(returning: true)
    while !renewalFinished { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    try check(renewalRestarts == 1 && !renewal.isWaiting, "A pending probe honors the renewed deadline")

    var failedProbe: Bool? = true, probeDone = false
    Task { @MainActor in
        failedProbe = await PermissionProcess.probe(executable: URL(fileURLWithPath: "/missing/CaptureStudio"))
        probeDone = true
    }
    while !probeDone { RunLoop.current.run(until: Date().addingTimeInterval(0.005)) }
    try check(failedProbe == nil, "An unavailable probe executable fails without a prompt or hang")

    let root = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureRecovery-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let clipboard = NSPasteboard(name: .init("CaptureRecovery-" + UUID().uuidString))
    defer { clipboard.releaseGlobally() }
    let history = HistoryStore(root: root)
    let model = EditorModel(history: history, clipboard: ImageClipboard(pasteboard: clipboard))
    let delegate = AppDelegate(model: model)
    model.load(DemoImage.make(), title: "Permission recovery fixture")
    model.beginTextEditing(at: CGPoint(x: 30, y: 40)); model.updateText("Keep this text")
    try check(delegate.prepareForPermissionRestart(), "Relaunch commits inline text and pending clipboard work")
    let saved = try history.read(history.list()[0])
    try check(saved.marks.first?.text == "Keep this text", "The restored archive contains the latest edit")
    try check(clipboard.data(forType: .png) != nil, "The edited image remains pasteable after restart")
    model.isCapturing = true
    try check(!delegate.prepareForPermissionRestart(), "A running capture cannot be interrupted by recovery")
    model.isCapturing = false
    let unavailable = EditorModel(history: HistoryStore(root: root.appendingPathComponent("offline"), requiresExistingRoot: true))
    unavailable.beginTextEditing(at: CGPoint(x: 10, y: 10)); unavailable.updateText("Unsaved")
    let offline = AppDelegate(model: unavailable)
    try check(!offline.prepareForPermissionRestart() && unavailable.error != nil,
        "Failed archiving keeps the app running with its edits intact")
    let unsaved = EditorModel(); unsaved.markUnsaved()
    try check(!AppDelegate(model: unsaved).prepareForPermissionRestart(), "An unarchived document is never discarded for a restart")
    return count
}
