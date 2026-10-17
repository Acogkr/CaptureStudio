import SwiftUI

struct EditorView: View {
    @ObservedObject private var localization = Localization.shared
    @ObservedObject var model: EditorModel
    @ObservedObject var updates: UpdateChecker
    @ObservedObject var shortcuts: CaptureShortcuts
    var cancelPermission: () -> Void = {}
    var openPermissionSettings: () -> Void = { CaptureService.openPermissionSettings() }
    let capture: (CaptureMode) -> Void
    private var colors: [(String, NSColor)] { [(L("Red"), .systemRed), (L("Orange"), .systemOrange), (L("Blue"), .systemBlue), (L("Green"), .systemGreen), (L("Black"), .black), (L("White"), .white)] }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    toolbar
                    Divider()
                    EditorCanvas(model: model)
                        .overlay(alignment: .top) {
                            if let toast = model.toast {
                                Label(toast, systemImage: "checkmark.circle.fill")
                                    .font(.system(size: 12)).padding(.horizontal, 14).padding(.vertical, 9)
                                    .background(.regularMaterial, in: Capsule()).padding(.top, 16)
                                    .transition(.opacity)
                            }
                        }
                    Divider()
                    footer
                }
                Divider()
                inspector
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .animation(.easeOut(duration: 0.15), value: model.toast)
        .disabled(model.isCapturing || model.isUpdatingArchive)

        .alert(L("Unable to Complete"), isPresented: Binding(get: { model.error != nil && !model.settingsWindowActive }, set: { if !$0 { model.error = nil } })) {
            Button(L("OK"), role: .cancel) { model.error = nil }
        } message: { Text(model.error ?? "") }
        .sheet(isPresented: $model.showPermission) {
            VStack(alignment: .leading, spacing: 16) {
                Image(systemName: "rectangle.dashed.badge.record").font(.system(size: 28)).foregroundStyle(.secondary)
                Text(L("Allow Screen Capture")).font(.system(size: 20, weight: .semibold))
                Text(L("Enable Capture Studio in Screen & System Audio Recording. The app checks automatically and restarts if needed. If access is still denied after an update, remove the old Capture Studio entry and add the current app again using +."))
                    .font(.system(size: 13)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button(L("Later")) { cancelPermission(); model.showPermission = false }.keyboardShortcut(.cancelAction)
                    Spacer()
                    Button(L("Open Screen Recording Settings")) {
                        model.showPermission = false
                        openPermissionSettings()
                    }.buttonStyle(.borderedProminent)
                }.padding(.top, 8)
            }.padding(28).frame(width: 380)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.isExample ? L("Sample Image") : model.title).font(.system(size: 14, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Text(model.isExample ? L("Choose a tool and try editing.") : model.dimensions + " px")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 24)
            UpdateButton(updates: updates)
            Button { model.showHistory.toggle() } label: {
                Image(systemName: "clock.arrow.circlepath").frame(width: 24, height: 24).contentShape(Rectangle())
            }
                .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Recent Images")).accessibilityLabel(L("Recent Images"))
                .popover(isPresented: $model.showHistory, arrowEdge: .bottom) { RecentImagesView(model: model) }
            Menu {
                Button(L("Open Image…")) { model.openImage() }
                Button(L("Paste Image")) { model.paste() }
            } label: { Label(L("Import"), systemImage: "photo") }
                .fixedSize().menuStyle(.borderlessButton).frame(width: 94).help(L("Open Image · ⌘O / Paste · ⌘V"))
            Menu {
                ForEach(CaptureMode.allCases, id: \.self) { mode in Button(mode.title) { capture(mode) } }
            } label: { Label(L("Capture"), systemImage: "viewfinder") }
            .fixedSize().menuStyle(.borderlessButton).frame(width: 88)
                .help(shortcuts.captureHelp)
            Divider().frame(height: 22).padding(.horizontal, 4)
            Button(L("Copy")) { model.copy() }.buttonStyle(.borderedProminent).help(L("Copy Image · ⌘C"))
            Button(L("Save…")) { model.save() }.help(L("Save as PNG · ⌘S"))
        }.padding(.horizontal, 22).frame(height: 74)
    }
    private var toolbar: some View {
        HStack(spacing: 3) {
            ForEach(EditorTool.allCases) { item in
                Button { model.tool = item; model.selectedID = nil } label: {
                    HStack(spacing: 6) {
                        Image(systemName: item.symbol).font(.system(size: 13, weight: .medium)).frame(width: 17)
                        Text(item.title).font(.system(size: 12, weight: model.tool == item ? .medium : .regular))
                    }.padding(.horizontal, 10).frame(height: 30)
                        .foregroundStyle(model.tool == item ? Color.primary : Color.secondary)
                        .background(model.tool == item ? Color(nsColor: .controlBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(model.tool == item ? Color.primary.opacity(0.09) : .clear, lineWidth: 1).allowsHitTesting(false))
                        // Plain buttons otherwise leave transparent padding outside the hit region.
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help(item.hint).accessibilityLabel(item.title)
                    .accessibilityAddTraits(model.tool == item ? [.isSelected] : [])
            }
            Spacer(minLength: 8)
            smallButton("arrow.uturn.backward", label: L("Undo"), disabled: !model.canUndo) { model.undo() }
            smallButton("arrow.uturn.forward", label: L("Redo"), disabled: !model.canRedo) { model.redo() }
        }.padding(.horizontal, 14).frame(height: 52)
    }
    private var inspector: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(model.tool.title).font(.system(size: 13, weight: .semibold)).padding(.bottom, 10)
            Text(model.tool.hint).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineSpacing(4).fixedSize(horizontal: false, vertical: true).frame(height: 74, alignment: .topLeading)
            Divider().padding(.bottom, 20)
            if [.arrow, .rectangle, .text].contains(model.tool) {
                sectionLabel(L("Color"))
                HStack(spacing: 5) {
                    ForEach(colors, id: \.0) { name, value in
                        Button { model.color = value } label: {
                            Circle().fill(Color(nsColor: value)).frame(width: 19, height: 19)
                                .overlay(Circle().stroke(Color.primary.opacity(0.12), lineWidth: 1))
                                .padding(3).overlay(Circle().stroke(model.color == value ? Color.primary.opacity(0.65) : .clear, lineWidth: 1.5))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).help(name).accessibilityLabel(name)
                            .accessibilityAddTraits(model.color == value ? [.isSelected] : [])
                    }
                }.padding(.top, 10).padding(.bottom, 26)
                if model.tool == .text {
                    sectionLabel(L("Text Size"))
                    Picker(L("Text Size"), selection: $model.fontSize) {
                        ForEach([20, 28, 36, 48, 64], id: \.self) { Text("\($0)").tag(CGFloat($0)) }
                    }.labelsHidden().padding(.top, 10)
                } else {
                    HStack { sectionLabel(L("Line Width")); Spacer(); Text("\(Int(model.stroke)) px").font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit() }
                    Slider(value: $model.stroke, in: 2...12, step: 1).padding(.top, 8).accessibilityLabel(L("Line Width"))
                }
            } else if model.tool == .redact {
                Picker(L("Redaction Style"), selection: Binding(get: { model.blindStyle }, set: { model.selectBlindStyle($0) })) {
                    ForEach(BlindStyle.allCases) { style in Text(style.title).tag(style) }
                }.pickerStyle(.segmented).labelsHidden()
                if model.blindStyle == .mosaic {
                    sectionLabel(L("Block Size")).padding(.top, 20)
                    Slider(value: Binding(get: { model.blockSize }, set: { model.setBlockSize($0) }), in: 12...64, step: 4)
                        .accessibilityLabel(L("Mosaic Block Size"))
                    Text(L("Use Cover to fully hide sensitive text."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).padding(.top, 12)
                } else {
                    Text(L("Covers the selected area with a solid fill, including when copied or saved."))
                        .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).padding(.top, 12)
                }
            } else if model.tool == .select {
                Button(L("Delete Annotation"), role: .destructive) { model.removeSelection() }
                    .disabled(model.selectedID == nil)
                Text(L("Press Delete to remove.\nDouble-click text to edit it."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4).padding(.top, 12)
            } else {
                Text(L("Press ⌘Z to restore the image after cropping."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineSpacing(4)
            }
            Spacer(minLength: 24)
            Divider().padding(.bottom, 16)
            Text(L("Drop an image or press ⌘V")).font(.system(size: 10)).foregroundStyle(.tertiary)
        }.padding(20).frame(width: 216).frame(maxHeight: .infinity)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
    }
    private var footer: some View {
        HStack {
            Text(model.dimensions + " px")
            if !model.historyStatus.isEmpty {
                Circle().fill(Color.secondary.opacity(0.5)).frame(width: 4, height: 4)
                if model.historyError != nil { Button(model.historyStatus) { model.flushHistory() }.buttonStyle(.plain).foregroundStyle(.orange) }
                else { Text(model.historyStatus) }
            } else if model.dirty { Text(L("Not Saved")) }
            Spacer()
            Text(L("Edits Copy Automatically"))
                .help(L("Edits are copied automatically. Press ⌘V in another app to paste."))
        }.font(.system(size: 11)).foregroundStyle(.secondary).padding(.horizontal, 20).frame(height: 34)
    }
    private func sectionLabel(_ value: String) -> some View { Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary) }
    private func smallButton(_ symbol: String, label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 26, height: 26).contentShape(Rectangle())
        }.buttonStyle(.plain).foregroundStyle(.secondary)
            .disabled(disabled).help(label).accessibilityLabel(label)
    }
}
