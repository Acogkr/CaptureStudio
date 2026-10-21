import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var error: String?
    private let readStatus: () -> SMAppService.Status
    private let register: () throws -> Void
    private let unregister: () throws -> Void
    private let openSettings: () -> Void

    init(readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         register: @escaping () throws -> Void = { try SMAppService.mainApp.register() },
         unregister: @escaping () throws -> Void = { try SMAppService.mainApp.unregister() },
         openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }) {
        self.readStatus = readStatus; self.register = register
        self.unregister = unregister; self.openSettings = openSettings
        status = readStatus()
    }

    var isEnabled: Bool { status == .enabled }
    var requiresApproval: Bool { status == .requiresApproval }

    func refresh() {
        let previous = status
        status = readStatus()
        if status != previous { error = nil }
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        error = nil
        guard enabled ? !isEnabled : status != .notRegistered else { return }
        do {
            if enabled { try register() } else { try unregister() }
            refresh()
        } catch {
            refresh()
            // Another system action may have completed the requested change.
            if enabled ? !isEnabled && !requiresApproval : status != .notRegistered {
                self.error = L("Could not change launch at login. {0}", error.localizedDescription)
            }
        }
    }

    func showSystemSettings() { openSettings() }

    static func isLoginLaunch(_ event: NSAppleEventDescriptor?) -> Bool {
        event?.eventClass == kCoreEventClass && event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}

struct LoginItemSettingsView: View {
    @ObservedObject var loginItem: LoginItem

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Launch at Login")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle(L("Launch at Login"), isOn: Binding(
                    get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            Text(L("Start in the menu bar at login, ready for capture shortcuts without opening the editor."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if loginItem.requiresApproval {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(L("Allow Capture Studio in Login Items to enable automatic startup."))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(L("Open Login Items")) { loginItem.showSystemSettings() }
                        .controlSize(.small).fixedSize()
                }
            }
            if let error = loginItem.error {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }.onAppear { loginItem.refresh() }
    }
}
