import AppKit
import Carbon

@MainActor
func runConfigurableShortcutTests() throws -> Int {
    var checks = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw NSError(domain: "ShortcutSettingsTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
        checks += 1
    }
    let domain = "CaptureShortcutTests-" + UUID().uuidString
    let defaults = UserDefaults(suiteName: domain)!
    defer { defaults.removePersistentDomain(forName: domain) }
    let shortcuts = CaptureShortcuts(preferences: defaults)
    defer { shortcuts.stop() }
    try check(shortcuts.bindings[.area] == CaptureShortcuts.defaults[.area] && shortcuts.bindings[.window] == nil && shortcuts.bindings[.screen] == nil,
        "Existing area shortcut is retained without claiming new global keys")
    let modifiers = UInt32(cmdKey | shiftKey | controlKey | optionKey)
    let keys: [CaptureMode: CaptureKey] = [.area: CaptureKey(keyCode: UInt16(kVK_F17), modifiers: modifiers),
        .window: CaptureKey(keyCode: UInt16(kVK_F18), modifiers: modifiers), .screen: CaptureKey(keyCode: UInt16(kVK_F19), modifiers: modifiers)]
    for mode in CaptureMode.allCases { try check(shortcuts.set(keys[mode], for: mode), "Each capture action accepts its own key") }
    var actions: [CaptureMode] = []
    shortcuts.start { actions.append($0) }
    try check(shortcuts.errors.isEmpty, "All three shortcuts register independently")
    for mode in CaptureMode.allCases {
        shortcuts.receive(mode, kind: UInt32(kEventHotKeyPressed))
        shortcuts.receive(mode, kind: UInt32(kEventHotKeyPressed))
        shortcuts.receive(mode, kind: UInt32(kEventHotKeyReleased))
    }
    try check(actions == CaptureMode.allCases, "Three global shortcuts route to the correct mode once per press")
    shortcuts.beginRecording(.window)
    shortcuts.receive(.area, kind: UInt32(kEventHotKeyPressed))
    try check(actions.count == 3, "Recording suspends all global capture actions")
    try check(!shortcuts.set(keys[.area], for: .window) && shortcuts.bindings[.window] == keys[.window],
        "Duplicate capture keys preserve the previous mapping")
    try check(!shortcuts.set(CaptureKey(keyCode: 0, modifiers: 0), for: .window), "Plain typing is rejected")
    try check(!shortcuts.set(CaptureKey(keyCode: UInt16(kVK_ANSI_Q), modifiers: UInt32(cmdKey)), for: .window), "Quit is protected")
    for code in [kVK_ANSI_3, kVK_ANSI_4, kVK_ANSI_5] {
        for modifiers in [UInt32(cmdKey | shiftKey), UInt32(cmdKey | shiftKey | controlKey)] {
            try check(CaptureKey(keyCode: UInt16(code), modifiers: modifiers).validationError == nil,
                "Screenshot combinations may be reassigned when their system bindings are disabled")
        }
    }
    shortcuts.cancelRecording()
    shortcuts.receive(.window, kind: UInt32(kEventHotKeyPressed))
    shortcuts.receive(.window, kind: UInt32(kEventHotKeyReleased))
    try check(actions.last == .window && actions.count == 4, "Cancellation restores registrations")
    let competing = GlobalCaptureShortcut(keyCode: UInt32(kVK_F20), modifiers: modifiers, id: 99)
    try competing.register {}
    defer { competing.stop() }
    shortcuts.beginRecording(.screen)
    let conflict = CaptureKey(keyCode: UInt16(kVK_F20), modifiers: modifiers)
    try check(!shortcuts.set(conflict, for: .screen) && shortcuts.bindings[.screen] == keys[.screen], "External conflict preserves the old mapping")
    try check(shortcuts.errors[.screen] != nil, "Conflict is shown beside its row")
    shortcuts.cancelRecording()
    shortcuts.beginRecording(.area)
    let changed = CaptureKey(keyCode: UInt16(kVK_F16), modifiers: modifiers)
    try check(shortcuts.set(changed, for: .area) && shortcuts.recording == nil, "A new key takes effect immediately")
    try check(CaptureShortcuts(preferences: defaults).bindings == shortcuts.bindings, "All settings survive restart")
    shortcuts.beginRecording(.screen)
    try check(shortcuts.set(nil, for: .screen), "A shortcut can be cleared")
    try check(CaptureShortcuts(preferences: defaults).bindings[.screen] == nil, "Cleared shortcuts stay cleared")
    shortcuts.beginRecording(.screen)
    _ = shortcuts.set(keys[.window], for: .screen)
    shortcuts.cancelRecording()
    try check(shortcuts.errors[.screen] == nil && shortcuts.bindings[.screen] == nil, "Cancel clears a rejected attempt for an unassigned action")
    let recorder = ShortcutRecorderButton()
    recorder.shortcuts = shortcuts; recorder.mode = .window
    func event(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
            context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }
    shortcuts.beginRecording(.window); recorder.handle(event(UInt16(kVK_Escape)))
    try check(shortcuts.recording == nil && shortcuts.bindings[.window] == keys[.window], "Escape cancels")
    shortcuts.beginRecording(.window); recorder.handle(event(UInt16(kVK_Delete)))
    try check(shortcuts.recording == nil && shortcuts.bindings[.window] == nil, "Delete clears only the selected action")
    try check(changed.display.contains("F16") && changed.menuEquivalent.unicodeScalars.first?.value == UInt32(NSF16FunctionKey), "Function-key labels match native menus")
    return checks
}
