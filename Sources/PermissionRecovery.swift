import AppKit
import CoreGraphics

/// Watches only after a denied capture. A fresh process distinguishes a stale
/// in-process permission result from a grant that is still unavailable.
@MainActor
final class PermissionRecovery {
    private let currentAccess: () -> Bool
    private let freshAccess: () async -> Bool?
    private let ready: () -> Void
    private let restart: () -> Bool
    private let now: () -> Date
    private var deadline: Date?
    private var generation = 0
    private var checking = false
    private var timer: Timer?
    var isWaiting: Bool { deadline != nil }

    init(currentAccess: @escaping () -> Bool,
         freshAccess: @escaping () async -> Bool? = { await PermissionProcess.probe() },
         now: @escaping () -> Date = Date.init,
         ready: @escaping () -> Void, restart: @escaping () -> Bool) {
        self.currentAccess = currentAccess; self.freshAccess = freshAccess
        self.now = now; self.ready = ready; self.restart = restart
    }

    func begin(automatically: Bool = true) {
        let wasWaiting = isWaiting
        deadline = now().addingTimeInterval(600)
        guard !wasWaiting else { return }
        generation += 1
        if automatically {
            timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor [weak self] in await self?.check() }
            }
        }
    }

    func stop() {
        deadline = nil; generation += 1
        timer?.invalidate(); timer = nil
    }

    func check() async {
        guard let deadline, !checking else { return }
        guard now() < deadline else { stop(); return }
        if currentAccess() { stop(); ready(); return }
        checking = true
        let attempt = generation
        let granted = await freshAccess()
        checking = false
        guard generation == attempt, isWaiting else { return }
        guard let activeDeadline = self.deadline, now() < activeDeadline else { stop(); return }
        if currentAccess() { stop(); ready() }
        else if granted == true, restart() { stop() }
    }

    deinit { timer?.invalidate() }
}

enum PermissionProcess {
    /// No prompt, capture, archive access or editor initialization in this mode.
    static func probe(executable: URL? = Bundle.main.executableURL) async -> Bool? {
        guard let executable else { return nil }
        return await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = executable
            task.arguments = ["--screen-permission-probe"]
            task.standardInput = FileHandle.nullDevice
            task.standardOutput = FileHandle.nullDevice
            task.standardError = FileHandle.nullDevice
            task.terminationHandler = { task in
                let result: Bool? = task.terminationReason == .exit && [0, 2].contains(task.terminationStatus)
                    ? task.terminationStatus == 0 : nil
                continuation.resume(returning: result)
            }
            do {
                try task.run()
                DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                    if task.isRunning { task.terminate() }
                }
            } catch { continuation.resume(returning: nil) }
        }
    }

    static func scheduleRestart() throws {
        guard let executable = Bundle.main.executableURL else { throw CocoaError(.fileNoSuchFile) }
        let helper = Process()
        helper.executableURL = executable
        helper.arguments = ["--reopen-after-exit", String(ProcessInfo.processInfo.processIdentifier)]
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        try helper.run()
    }

    /// Called before acquiring the archive lock. Never reopen if termination was
    /// cancelled; never compete with the old editor for the same archive.
    @MainActor static func reopen(after pid: pid_t) {
        guard pid > 1, pid != ProcessInfo.processInfo.processIdentifier else { return }
        let parent = NSRunningApplication(processIdentifier: pid)
        let deadline = Date().addingTimeInterval(30)
        while let parent, !parent.isTerminated, Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        guard parent?.isTerminated != false else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.arguments = ["--permission-recovered"]
        var completed = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            completed = true
        }
        let launchDeadline = Date().addingTimeInterval(15)
        while !completed, Date() < launchDeadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
    }
}
