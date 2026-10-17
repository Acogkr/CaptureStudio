import AppKit
import SwiftUI

struct ArchivePreferences: Codable, Equatable {
    var folderPath: String?
    var autoDelete = false
    var days = 30
    static let allowedDays = [7, 30, 90, 365]
    private static let key = "archivePreferences"
    var folder: URL? { folderPath.map { URL(fileURLWithPath: $0, isDirectory: true) } }
    var retentionDays: Int? { autoDelete ? days : nil }

    static func load(from defaults: UserDefaults) -> ArchivePreferences {
        guard let data = defaults.data(forKey: key),
              var value = try? JSONDecoder().decode(Self.self, from: data) else { return Self() }
        if !allowedDays.contains(value.days) { value.autoDelete = false; value.days = 30 }
        if let path = value.folderPath, !path.hasPrefix("/") { value.folderPath = nil }
        return value
    }
    @discardableResult
    func save(to defaults: UserDefaults, synchronize: Bool = false) -> Bool {
        guard let data = try? JSONEncoder().encode(self) else { return false }
        defaults.set(data, forKey: Self.key)
        // Folder migration must durably record the new location before retiring the old copy.
        return !synchronize || defaults.synchronize()
    }
}

struct ArchiveSettingsView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var model: EditorModel
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var shortcuts: CaptureShortcuts
    let chooseFolder: () -> Void

    private var folder: URL? { model.history?.root }
    private var folderPath: String {
        guard let folder else { return L("Archive folder unavailable.") }
        return (folder.path as NSString).abbreviatingWithTildeInPath
    }

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Language")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Picker(L("Language"), selection: $localization.selection) {
                        Text(L("System Default")).tag("system")
                        Divider()
                        ForEach(localization.sortedLanguages) { language in
                            Text(language.nativeName).tag(language.id)
                        }
                    }.labelsHidden().controlSize(.small).frame(width: 230)
                }
                Text(L("Choose the app language. Changes take effect immediately."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            ShortcutSettingsView(shortcuts: shortcuts)
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Archive Folder")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Button(L("Show in Finder")) { model.revealArchive() }
                        .controlSize(.small)
                }
                HStack(spacing: 10) {
                    Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(folder?.lastPathComponent ?? L("Archive Folder"))
                            .font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                        Text(folderPath)
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .help(folder?.path ?? folderPath)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Button(L("Change…"), action: chooseFolder).controlSize(.small)
                }
                Text(L("Changing folders also moves your images and edits."))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(L("Automatically Delete Old Images")).font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Toggle(L("Automatically Delete Old Images"), isOn: Binding(get: { model.archivePreferences.autoDelete },
                        set: { model.setAutoDelete($0) }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                        .frame(width: 110, alignment: .trailing)
                }
                HStack {
                    Text(L("Keep Images For")).font(.system(size: 13))
                    Spacer()
                    Picker(L("Keep Images For"), selection: Binding(get: { model.archivePreferences.days },
                        set: { model.setRetentionDays($0) })) {
                        ForEach(ArchivePreferences.allowedDays, id: \.self) { days in
                            Text(days == 365 ? L("1 Year") : L("{0} Days", days)).tag(days)
                        }
                    }.labelsHidden().controlSize(.small).frame(width: 110)
                        // AppKit caches the selected title while a pop-up is disabled.
                        .id(L10n.code)
                        .disabled(!model.archivePreferences.autoDelete)
                }
                Text(model.archivePreferences.autoDelete
                    ? L("Images move to Trash when the retention period since their last edit expires. The open image is kept.")
                    : L("Keep all images until you delete them, with no count or storage limit."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)
            }
            if model.isUpdatingArchive {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L("Moving Archive…")).font(.system(size: 12))
                }
            } else if let message = model.archiveMessage, !message.isEmpty {
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            UpdateSettingsView(updates: updates)
        }.padding(24).frame(width: 520, alignment: .leading)
        }
            .disabled(model.isUpdatingArchive || model.isCapturing)
            .alert(L("Unable to Complete"), isPresented: Binding(
                get: { model.settingsWindowActive && model.error != nil },
                set: { if !$0 { model.error = nil } }
            )) {
                Button(L("OK"), role: .cancel) { model.error = nil }
            } message: { Text(model.error ?? "") }
    }
}
