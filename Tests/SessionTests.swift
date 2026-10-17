import Foundation

func runSessionTests() throws -> Int {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("CaptureSessionTest-" + UUID().uuidString)
    defer { try? fm.removeItem(at: root) }
    var lock = try SessionLock(directory: root)
    guard lock != nil else { throw NSError(domain: "SessionTest", code: 1) }
    func child(_ folder: URL) throws -> Int32 {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        task.arguments = ["--session-lock-probe", folder.path]
        try task.run(); task.waitUntilExit()
        return task.terminationStatus
    }
    guard try child(root) == 3 else { throw NSError(domain: "SessionTest", code: 2) }
    guard try child(root.appendingPathComponent("independent")) == 0 else { throw NSError(domain: "SessionTest", code: 3) }
    withExtendedLifetime(lock) {}
    lock = nil
    guard try child(root) == 0 else { throw NSError(domain: "SessionTest", code: 4) }
    return 4
}
