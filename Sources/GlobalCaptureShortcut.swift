import AppKit
import Carbon

@MainActor
final class GlobalCaptureShortcut {
    static let eventID = EventHotKeyID(signature: 0x43535455, id: 1) // CSTU
    private let registrationID: EventHotKeyID
    private let keyCode: UInt32
    private let modifiers: UInt32
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var pressed = false
    private var action: (() -> Void)?

    init(keyCode: UInt32 = UInt32(kVK_ANSI_2), modifiers: UInt32 = UInt32(cmdKey | shiftKey), id: UInt32 = 1) {
        self.registrationID = EventHotKeyID(signature: Self.eventID.signature, id: id)
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    func register(action: @escaping () -> Void) throws {
        self.action = action
        guard hotKey == nil else { return }
        let events = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            // Application-target Carbon events are delivered by the main event loop.
            return MainActor.assumeIsolated {
                let shortcut = Unmanaged<GlobalCaptureShortcut>.fromOpaque(context).takeUnretainedValue()
                return shortcut.receive(id: id, kind: GetEventKind(event))
            }
        }, events.count, events, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard installed == noErr else { stop(); throw ShortcutError.registration(installed) }
        let registered = RegisterEventHotKey(keyCode, modifiers, registrationID, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registered == noErr else { stop(); throw ShortcutError.registration(registered) }
    }

    @discardableResult
    func receive(id: EventHotKeyID, kind: UInt32) -> OSStatus {
        guard hotKey != nil, id.signature == registrationID.signature, id.id == registrationID.id else {
            return OSStatus(eventNotHandledErr)
        }
        switch kind {
        case UInt32(kEventHotKeyPressed):
            guard !pressed else { return noErr }
            pressed = true
            action?()
        case UInt32(kEventHotKeyReleased): pressed = false
        default: return OSStatus(eventNotHandledErr)
        }
        return noErr
    }

    func stop() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil; handler = nil; pressed = false; action = nil
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}

enum ShortcutError: LocalizedError {
    case registration(OSStatus)
    var errorDescription: String? {
        switch self {
        case .registration(let status) where status == eventHotKeyExistsErr:
            return L("This shortcut is already registered by another app. Choose a different combination.")
        case .registration:
            return L("Could not register this shortcut. Try another combination.")
        }
    }
}
