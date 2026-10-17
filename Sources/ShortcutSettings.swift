import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @ObservedObject var shortcuts: CaptureShortcuts
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Capture Shortcuts")).font(.system(size: 13, weight: .semibold))
            ForEach(CaptureMode.allCases, id: \.self) { mode in
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        Text(mode.title).font(.system(size: 13))
                        Spacer()
                        ShortcutRecorder(shortcuts: shortcuts, mode: mode).frame(width: 160, height: 26)
                    }
                    if let error = shortcuts.errors[mode] {
                        Text(error).font(.system(size: 11)).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text(L("Click a shortcut and press the new keys. Esc cancels; Delete clears it. Works while Capture Studio is running, even in other apps."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct ShortcutRecorder: NSViewRepresentable {
    @ObservedObject var shortcuts: CaptureShortcuts
    let mode: CaptureMode
    func makeNSView(context: Context) -> ShortcutRecorderButton {
        let button = ShortcutRecorderButton()
        button.bezelStyle = .rounded
        button.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        button.target = button; button.action = #selector(ShortcutRecorderButton.begin)
        button.setButtonType(.momentaryPushIn)
        return button
    }
    func updateNSView(_ button: ShortcutRecorderButton, context: Context) {
        button.shortcuts = shortcuts; button.mode = mode
        button.isEnabled = context.environment.isEnabled
        if !button.isEnabled { button.cancel() }
        if shortcuts.recording != mode { button.end() }
        button.title = shortcuts.recording == mode ? L("Press Shortcut…") : shortcuts.label(for: mode)
        button.setAccessibilityLabel(mode.title + " · " + button.title)
        button.setAccessibilityHelp(L("Click to change the global capture shortcut."))
    }
    static func dismantleNSView(_ button: ShortcutRecorderButton, coordinator: ()) { button.cancel() }
}

final class ShortcutRecorderButton: NSButton {
    var shortcuts: CaptureShortcuts?
    var mode: CaptureMode = .area
    private var monitor: Any?
    override var acceptsFirstResponder: Bool { true }
    @objc func begin() {
        guard isEnabled, let window, let shortcuts else { return }
        window.makeFirstResponder(self)
        shortcuts.beginRecording(mode)
        title = L("Press Shortcut…")
        end()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.shortcuts?.recording == self.mode,
                  self.window?.isKeyWindow == true, self.window?.firstResponder === self else { return event }
            self.handle(event)
            return nil
        }
    }
    func handle(_ event: NSEvent) {
        guard !event.isARepeat, let shortcuts else { return }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if event.keyCode == 53 && modifiers.isEmpty { cancel(); return }
        if [51,117].contains(event.keyCode) && modifiers.isEmpty {
            if shortcuts.set(nil, for: mode) { end() }
        } else if shortcuts.set(CaptureKey(event: event), for: mode) { end() }
    }
    func end() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
    func cancel() {
        end()
        if shortcuts?.recording == mode { shortcuts?.cancelRecording() }
    }
    override func resignFirstResponder() -> Bool { cancel(); return super.resignFirstResponder() }
    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil { cancel() }
        super.viewWillMove(toWindow: newWindow)
    }
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
}
