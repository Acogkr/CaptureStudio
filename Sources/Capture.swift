import AppKit
import CoreGraphics

enum CaptureMode: String, CaseIterable {
    case area, window, screen
    var title: String {
        switch self {
        case .area: return L("Capture Area")
        case .window: return L("Capture Window")
        case .screen: return L("Capture Full Screen")
        }
    }
    var arguments: [String] {
        switch self {
        case .area: return ["-i", "-s"]
        case .window: return ["-i", "-w", "-o"]
        case .screen: return ["-m"]
        }
    }
}

@MainActor
final class CapturePermission {
    private let preflight: () -> Bool
    private let request: () -> Bool
    private var requested = false

    init(preflight: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         request: @escaping () -> Bool = { CGRequestScreenCaptureAccess() }) {
        self.preflight = preflight
        self.request = request
    }

    var isGranted: Bool { preflight() }

    func authorize() -> Bool {
        if isGranted { return true }
        // Recheck on every attempt, but don't repeatedly trigger the OS prompt.
        guard !requested else { return false }
        requested = true
        return request()
    }
}

@MainActor
final class CaptureService {
    private var process: Process?
    private let permission: CapturePermission
    private let makeProcess: (CaptureMode, URL) -> Process
    var lastExternalApplication: NSRunningApplication?
    var willCapture: (() -> Void)?
    var didCapture: ((CGImage, NSScreen?) -> Void)?
    var needsPermission: (() -> Void)?
    var hasPermission: Bool { permission.isGranted }

    init(permission: CapturePermission? = nil, makeProcess: ((CaptureMode, URL) -> Process)? = nil) {
        self.permission = permission ?? CapturePermission()
        self.makeProcess = makeProcess ?? { mode, output in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            task.arguments = ["-x", "-t", "png"] + mode.arguments + [output.path]
            return task
        }
    }

    func refreshPermission(model: EditorModel) {
        guard model.showPermission, permission.isGranted else { return }
        model.showPermission = false
        model.notify(L("Screen capture is ready."))
    }

    func start(_ mode: CaptureMode, model: EditorModel) {
        guard !model.isCapturing, !model.isUpdatingArchive, model.window?.attachedSheet == nil,
              NSApp.windows.allSatisfy({ $0.attachedSheet == nil }), NSApp.modalWindow == nil else { return }
        model.confirmReplacement { [weak self, weak model] in
            guard let self, let model else { return }
            guard self.permission.authorize() else {
                self.showEditor(model)
                model.showPermission = true
                self.needsPermission?()
                return
            }
            model.showPermission = false
            self.perform(mode, model: model)
        }
        if model.error != nil { showEditor(model) }
    }
    private func perform(_ mode: CaptureMode, model: EditorModel) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CaptureStudio-\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        catch { model.error = error.localizedDescription; showEditor(model); return }
        let output = directory.appendingPathComponent("capture.png")
        let restoreEditorOnCancel = NSApp.isActive && model.window?.isVisible == true && model.window?.isMiniaturized == false
        let front = NSWorkspace.shared.frontmostApplication
        let returnTo = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? lastExternalApplication : front
        willCapture?()
        model.isCapturing = true
        model.window?.orderOut(nil)
        if NSApp.isActive, let returnTo, !returnTo.isTerminated,
           returnTo.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            NSApp.yieldActivation(to: returnTo)
            returnTo.activate(options: [])
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self, weak model] in
            guard let self, let model else { try? FileManager.default.removeItem(at: directory); return }
            let task = self.makeProcess(mode, output)
            let errors = Pipe()
            task.standardError = errors
            task.standardOutput = FileHandle.nullDevice
            task.terminationHandler = { [weak self, weak model] task in
                let errorData = errors.fileHandleForReading.readDataToEndOfFile()
                DispatchQueue.main.async { [weak self, weak model] in
                    defer { try? FileManager.default.removeItem(at: directory) }
                    guard let self, let model else { return }
                    self.process = nil
                    model.isCapturing = false
                    if FileManager.default.fileExists(atPath: output.path) {
                        do {
                            let formatter = DateFormatter()
                            formatter.dateFormat = "yyyy-MM-dd HH.mm.ss"
                            let image = try ImageRenderer.load(output)
                            guard model.loadCapture(image, title: "Capture \(formatter.string(from: Date()))") else {
                                self.showEditor(model); return
                            }
                            let screen = mode == .screen ? NSScreen.screens.first
                                : NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                            self.didCapture?(image, screen)
                        } catch { model.error = error.localizedDescription; self.showEditor(model) }
                    } else if !self.permission.isGranted {
                        self.showEditor(model); model.showPermission = true
                        self.needsPermission?()
                    } else if mode == .screen || task.terminationReason != .exit || !errorData.isEmpty {
                        model.error = EditorError.capture.localizedDescription; self.showEditor(model)
                    } else if restoreEditorOnCancel {
                        // A cancelled global capture must leave the user's other app in front.
                        self.showEditor(model)
                    }
                }
            }
            self.process = task
            do { try task.run() }
            catch {
                self.process = nil
                model.isCapturing = false
                self.showEditor(model)
                model.error = error.localizedDescription
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }
    private func showEditor(_ model: EditorModel) {
        model.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func stop() { process?.terminate() }
    static func openPermissionSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }
}
