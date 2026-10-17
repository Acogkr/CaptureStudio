import AppKit
import Carbon

@MainActor
func runShortcutTests() throws -> Int {
    var count = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        count += 1
    }
    // Test registration without occupying the user's capture shortcut.
    let modifiers = UInt32(cmdKey | shiftKey | controlKey | optionKey)
    let shortcut = GlobalCaptureShortcut(keyCode: UInt32(kVK_F20), modifiers: modifiers)
    let competing = GlobalCaptureShortcut(keyCode: UInt32(kVK_F20), modifiers: modifiers)
    defer { shortcut.stop(); competing.stop() }
    var activations = 0
    try shortcut.register { activations += 1 }
    check(true, "Global hotkey registers with macOS")
    do {
        try competing.register { activations += 100 }
        check(false, "Conflicting registration must fail")
    } catch ShortcutError.registration(let status) {
        check(status == eventHotKeyExistsErr, "Conflicting hotkey is reported without stealing the existing shortcut")
    }
    let id = GlobalCaptureShortcut.eventID
    let down = UInt32(kEventHotKeyPressed), up = UInt32(kEventHotKeyReleased)
    shortcut.receive(id: EventHotKeyID(signature: 0, id: id.id), kind: down)
    check(activations == 0, "Foreign hotkey events do not start capture")
    shortcut.receive(id: id, kind: down)
    shortcut.receive(id: id, kind: down)
    check(activations == 1, "Holding the shortcut produces one capture")
    shortcut.receive(id: id, kind: up)
    shortcut.receive(id: id, kind: down)
    check(activations == 2, "Releasing and pressing again starts another capture")
    shortcut.stop()
    shortcut.receive(id: id, kind: down)
    check(activations == 2, "Queued events after unregister are ignored")
    try competing.register { activations += 1 }
    check(true, "Unregister releases the system shortcut")
    competing.stop()
    try shortcut.register { activations += 1 }
    try shortcut.register { activations += 1 }
    shortcut.receive(id: id, kind: down)
    check(activations == 3, "Registering twice is idempotent and restarting clears held-key state")
    shortcut.stop()

    do {
        let scoped = GlobalCaptureShortcut(keyCode: UInt32(kVK_F20), modifiers: modifiers)
        try scoped.register {}
    }
    try competing.register {}
    check(true, "Deallocation releases the native event handler and hotkey")
    competing.stop()

    // Exercise the installed Carbon callback, including extraction of the hotkey ID.
    // These events stay in this test process; no system-wide keyboard input is sent.
    activations = 0
    try shortcut.register { activations += 1 }
    func dispatch(_ kind: UInt32) -> OSStatus {
        var event: EventRef?
        let created = CreateEvent(nil, OSType(kEventClassKeyboard), kind, 0, 0, &event)
        guard created == noErr, let event else { return created }
        defer { ReleaseEvent(event) }
        var eventID = id
        let attached = SetEventParameter(event, EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID), MemoryLayout<EventHotKeyID>.size, &eventID)
        guard attached == noErr else { return attached }
        return SendEventToEventTarget(event, GetApplicationEventTarget())
    }
    check(dispatch(down) == noErr && activations == 1, "Native Carbon callback routes the registered hotkey")
    check(dispatch(down) == noErr && activations == 1, "Native callback suppresses a repeated press")
    check(dispatch(up) == noErr && dispatch(down) == noErr && activations == 2,
        "Native release event allows the next capture")
    return count
}
