import AppKit
import Carbon
import Combine

struct CaptureKey: Codable, Equatable {
    let keyCode: UInt16
    let modifiers: UInt32
    static let allowedModifiers = UInt32(cmdKey | controlKey | optionKey | shiftKey)
    init(keyCode: UInt16, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers & Self.allowedModifiers
    }
    init(event: NSEvent) {
        var value: UInt32 = 0
        if event.modifierFlags.contains(.command) { value |= UInt32(cmdKey) }
        if event.modifierFlags.contains(.control) { value |= UInt32(controlKey) }
        if event.modifierFlags.contains(.option) { value |= UInt32(optionKey) }
        if event.modifierFlags.contains(.shift) { value |= UInt32(shiftKey) }
        self.init(keyCode: event.keyCode, modifiers: value)
    }
    var flags: NSEvent.ModifierFlags {
        var result: NSEvent.ModifierFlags = []
        if modifiers & UInt32(cmdKey) != 0 { result.insert(.command) }
        if modifiers & UInt32(controlKey) != 0 { result.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { result.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { result.insert(.shift) }
        return result
    }
    static let special: [UInt16: String] = [
        36: "↩", 48: "⇥", 49: "Space", 51: "⌫", 53: "⎋", 76: "⌤", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑", 115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
        101: "F9", 109: "F10", 103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15",
        106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
    ]
    var keyName: String {
        if let name = Self.special[keyCode] { return name == "Space" ? L("Space") : name }
        guard keyCode <= 126, ![54,55,56,57,58,59,60,61,62,63,71].contains(keyCode) else { return "" }
        let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "" }
        let data = unsafeBitCast(pointer, to: CFData.self)
        guard let bytes = CFDataGetBytePtr(data) else { return "" }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
            OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return "" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
    var display: String {
        (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "") + keyName
    }
    var menuEquivalent: String {
        if keyCode == 49 { return " " }
        if let name = Self.special[keyCode], name.hasPrefix("F"), let number = Int(name.dropFirst()) {
            return String(UnicodeScalar(NSF1FunctionKey + number - 1)!)
        }
        let special: [UInt16: Int] = [36: 13, 48: 9, 51: 8, 53: 27, 76: 3, 117: NSDeleteFunctionKey,
            123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey, 125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
            115: NSHomeFunctionKey, 119: NSEndFunctionKey, 116: NSPageUpFunctionKey, 121: NSPageDownFunctionKey]
        if let code = special[keyCode] { return String(UnicodeScalar(code)!) }
        return keyName.lowercased()
    }
    var validationError: String? {
        guard modifiers == modifiers & Self.allowedModifiers, !keyName.isEmpty,
              modifiers & UInt32(cmdKey | controlKey) != 0 else {
            return L("Include Command or Control in the shortcut.")
        }
        // Protect editing/window commands. Screenshot keys can be reassigned after
        // disabling their macOS bindings; exclusive registration checks availability.
        let command = UInt32(cmdKey), shift = UInt32(shiftKey)
        let standardKeys = [kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_Z, kVK_ANSI_X, kVK_ANSI_C, kVK_ANSI_V,
                            kVK_ANSI_Q, kVK_ANSI_W, kVK_ANSI_O, kVK_ANSI_P, kVK_ANSI_M, kVK_ANSI_Comma, kVK_ANSI_H]
        if (modifiers == command || modifiers == command | shift),
           standardKeys.contains(Int(keyCode)) { return L("This combination is reserved for a standard command.") }
        if modifiers == command | shift, keyCode == kVK_ANSI_R { return L("This combination is reserved for a standard command.") }
        if keyCode == 49 && modifiers == command { return L("This combination is reserved for a standard command.") }
        return nil
    }
}

@MainActor
final class CaptureShortcuts: ObservableObject {
    static let preferenceKey = "CaptureShortcuts"
    static let defaults: [CaptureMode: CaptureKey] = [.area: CaptureKey(keyCode: UInt16(kVK_ANSI_2), modifiers: UInt32(cmdKey | shiftKey))]
    @Published private(set) var bindings: [CaptureMode: CaptureKey]
    @Published private(set) var recording: CaptureMode?
    @Published private(set) var errors: [CaptureMode: String] = [:]
    var didChange: (() -> Void)?
    private let preferences: UserDefaults
    private var registrations: [CaptureMode: GlobalCaptureShortcut] = [:]
    private var running = false
    private var action: ((CaptureMode) -> Void)?
    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: Self.preferenceKey),
           let saved = try? JSONDecoder().decode([String: CaptureKey].self, from: data) {
            var loaded: [CaptureMode: CaptureKey] = [:]
            for mode in CaptureMode.allCases {
                if let key = saved[mode.rawValue], key.validationError == nil, !loaded.values.contains(key) { loaded[mode] = key }
            }
            bindings = loaded
        } else { bindings = Self.defaults }
    }
    func start(_ action: @escaping (CaptureMode) -> Void) {
        self.action = action; running = true
        if recording == nil { registerBindings() }
    }
    func stop() {
        running = false; recording = nil
        unregister(); action = nil
    }
    private func unregister() { registrations.values.forEach { $0.stop() }; registrations.removeAll() }
    private func makeRegistration(_ mode: CaptureMode, _ key: CaptureKey) throws -> GlobalCaptureShortcut {
        let registration = GlobalCaptureShortcut(keyCode: UInt32(key.keyCode), modifiers: key.modifiers,
            id: UInt32(CaptureMode.allCases.firstIndex(of: mode)! + 1))
        try registration.register { [weak self] in
            guard let self, self.recording == nil else { return }
            self.action?(mode)
        }
        return registration
    }
    private func registerBindings() {
        guard running, recording == nil else { return }
        for mode in CaptureMode.allCases where registrations[mode] == nil {
            guard let key = bindings[mode] else { continue }
            do { registrations[mode] = try makeRegistration(mode, key); errors[mode] = nil }
            catch { errors[mode] = error.localizedDescription }
        }
    }
    func beginRecording(_ mode: CaptureMode) {
        unregister(); recording = mode; errors[mode] = nil
    }
    func cancelRecording() {
        if let mode = recording { errors[mode] = nil }
        recording = nil
        registerBindings()
    }
    @discardableResult
    func set(_ key: CaptureKey?, for mode: CaptureMode) -> Bool {
        if let key {
            if let error = key.validationError { errors[mode] = error; return false }
            if bindings.contains(where: { $0.key != mode && $0.value == key }) {
                errors[mode] = L("Another capture action already uses this shortcut."); return false
            }
        }
        // Keep the existing mapping on validation/registration failure. While recording,
        // old global shortcuts are suspended so typing them cannot start a capture.
        if recording == nil, bindings[mode] == key { return true }
        var replacement: GlobalCaptureShortcut?
        if running, let key {
            do { replacement = try makeRegistration(mode, key) }
            catch { errors[mode] = error.localizedDescription; return false }
        }
        registrations[mode]?.stop()
        registrations[mode] = replacement
        bindings[mode] = key
        let saved = Dictionary(uniqueKeysWithValues: bindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(saved) { preferences.set(data, forKey: Self.preferenceKey) }
        errors[mode] = nil; recording = nil
        registerBindings()
        didChange?()
        return true
    }
    func label(for mode: CaptureMode) -> String { bindings[mode]?.display ?? L("Not Set") }
    var captureHelp: String {
        CaptureMode.allCases.map { mode in mode.title + " · " + label(for: mode) }.joined(separator: "\n")
    }
    // Routes test-process Carbon events through the actual native handlers.
    #if CAPTURE_TESTING
    func receive(_ mode: CaptureMode, kind: UInt32) {
        registrations[mode]?.receive(id: EventHotKeyID(signature: GlobalCaptureShortcut.eventID.signature,
            id: UInt32(CaptureMode.allCases.firstIndex(of: mode)! + 1)), kind: kind)
    }
    #endif
}
