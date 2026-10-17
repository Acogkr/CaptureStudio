import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var updates: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("Automatically check for updates")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Toggle(L("Automatically check for updates"), isOn: $updates.automaticallyChecks)
                    .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    .frame(width: 110, alignment: .trailing)
            }
            HStack(spacing: 12) {
                Text(L("Current Version {0}", AppVersion.current)).font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                Button(updates.actionTitle) { updates.performAction() }
                    .controlSize(.small).disabled(updates.isChecking)
            }
            Text(updates.status.message)
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Checks GitHub once a day. Downloads open on the release page."))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .help(L("Update checks do not send your images or edits."))
        }
    }
}


struct UpdateButton: View {
    @ObservedObject var updates: UpdateChecker
    @State private var openFailed = false
    var body: some View {
        if let release = updates.availableRelease {
            Button { openFailed = !updates.openRelease() } label: {
                Label(L("Update"), systemImage: "arrow.down.circle")
            }
            .buttonStyle(.borderedProminent).tint(.blue).controlSize(.small).fixedSize()
            .help(L("Version {0} is available.", release.displayVersion))
            .accessibilityLabel(L("Update Available ({0})…", release.displayVersion))
            .alert(L("Unable to Complete"), isPresented: $openFailed) {
                Button(L("OK"), role: .cancel) {}
            } message: { Text(UpdateCheckError.openFailed.message) }
        }
    }
}
