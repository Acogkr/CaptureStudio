import AppKit

@MainActor
func runCaptureTests() throws -> Int {
    var count = 0
    func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        count += 1
    }
    var granted = false
    var requests = 0
    let permission = CapturePermission(preflight: { granted }, request: { requests += 1; return false })
    check(!permission.authorize() && requests == 1, "First denied capture requests permission once")
    check(!permission.authorize() && requests == 1, "Repeated denied captures do not repeat the OS prompt")
    granted = true
    check(permission.authorize() && requests == 1, "Permission granted in Settings is detected without another request")
    granted = false
    check(!permission.authorize(), "Revoked permission is not cached as allowed")
    let allowed = CapturePermission(preflight: { true }, request: { requests += 1; return false })
    check(allowed.authorize() && requests == 1, "Existing permission skips the request")
    let immediate = CapturePermission(preflight: { false }, request: { true })
    check(immediate.authorize(), "Permission granted by the OS request allows capture")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureProcessTests-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let fixture = folder.appendingPathComponent("input.png")
    try ImageRenderer.png(DemoImage.make()).write(to: fixture)
    let pasteboard = NSPasteboard(name: .init("CaptureProcessTests-" + UUID().uuidString))
    defer { pasteboard.releaseGlobally() }
    func run(_ mode: CaptureMode, script: String, status: String, revoke: Bool = false, duplicate: Bool = false) throws {
        pasteboard.clearContents(); pasteboard.setString("Keep previous clipboard", forType: .string)
        let model = EditorModel(clipboard: ImageClipboard(pasteboard: pasteboard))
        let previous = model.state.id
        var access = true, permissions = 0, previews = 0, processes = 0
        var temporaryOutput: URL?
        let service = CaptureService(permission: CapturePermission(preflight: { access }, request: { false }),
            makeProcess: { _, output in
                processes += 1; temporaryOutput = output
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", script, "capture-test", output.path, fixture.path]
                return process
            })
        service.needsPermission = { permissions += 1 }
        service.didCapture = { _, _ in previews += 1 }
        service.start(mode, model: model)
        if duplicate { service.start(mode, model: model) }
        if revoke { access = false }
        let deadline = Date().addingTimeInterval(5)
        while model.isCapturing && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        check(!model.isCapturing && processes == 1, "Capture subprocess completes once: \(status)")
        check(temporaryOutput.map { !FileManager.default.fileExists(atPath: $0.deletingLastPathComponent().path) } == true,
            "Temporary capture data is removed: \(status)")
        if status == "success" {
            check(model.state.id != previous && previews == 1 && model.error == nil && pasteboard.data(forType: .png) != nil,
                "Successful capture publishes its preview and clipboard once")
        } else {
            check(model.state.id == previous && previews == 0 && pasteboard.string(forType: .string) == "Keep previous clipboard",
                "Failed/cancelled capture preserves image and clipboard: \(status)")
            check((model.error != nil) == (status == "failure") && (model.showPermission && permissions == 1) == (status == "permission"),
                "Capture reports the correct result: \(status)")
        }
    }
    try run(.screen, script: "exit 0", status: "failure")
    try run(.screen, script: "exit 9", status: "failure")
    try run(.area, script: "exit 1", status: "cancelled")
    try run(.window, script: "exit 0", status: "cancelled")
    try run(.area, script: "printf 'capture unavailable' >&2; exit 0", status: "failure")
    try run(.area, script: "kill -TERM $$", status: "failure")
    try run(.screen, script: "exit 1", status: "permission", revoke: true)
    try run(.screen, script: "printf 'invalid PNG' > \"$1\"", status: "failure")
    try run(.screen, script: "cp \"$2\" \"$1\"", status: "success", duplicate: true)
    return count
}
