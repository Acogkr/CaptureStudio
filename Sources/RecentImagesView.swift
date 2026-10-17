import SwiftUI

struct RecentImagesView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("Recent Images")).font(.system(size: 14, weight: .semibold))
                Spacer()
                Text(L("Images: {0}", model.recents.count)).font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            if model.recents.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle").font(.system(size: 24)).foregroundStyle(.tertiary)
                    Text(L("Take a capture or open an image.")).font(.system(size: 12)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity).frame(height: 140)
            } else {
                ScrollView {
                    LazyVStack(spacing: 3) {
                        ForEach(model.recents) { item in
                            Button { model.restoreRecent(item) } label: {
                                HStack(spacing: 12) {
                                    thumbnail(item)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.title).font(.system(size: 12, weight: .medium)).lineLimit(1).truncationMode(.middle)
                                        Text("\(item.width) × \(item.height) · " + L10n.date(item.updatedAt))
                                            .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 0)
                                    if model.currentHistoryID == item.id { Image(systemName: "checkmark").font(.system(size: 11)).foregroundStyle(.secondary) }
                                }.padding(8).contentShape(Rectangle())
                                    .background(model.currentHistoryID == item.id ? Color.primary.opacity(0.06) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            }.buttonStyle(.plain)
                                .accessibilityLabel(L("Recent image: ") + item.title)
                                .contextMenu { Button(L("Remove from Recents"), role: .destructive) { model.removeRecent(item) } }
                        }
                    }.padding(8)
                }.frame(maxHeight: 360)
            }
            Divider()
            Text(model.archivePreferences.autoDelete ? L("Kept for {0} days · Change in Settings", model.archivePreferences.days) : L("Auto-delete off · Change folder in Settings"))
                .font(.system(size: 10)).foregroundStyle(.secondary).padding(14)
        }.frame(width: 360)
    }
    @ViewBuilder private func thumbnail(_ item: RecentImage) -> some View {
        if let history = model.history, let image = NSImage(contentsOf: history.thumbnailURL(item)) {
            Image(nsImage: image).resizable().aspectRatio(contentMode: .fit).frame(width: 70, height: 48)
                .background(Color.primary.opacity(0.04)).clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            Image(systemName: "photo").foregroundStyle(.tertiary).frame(width: 70, height: 48)
        }
    }
}
