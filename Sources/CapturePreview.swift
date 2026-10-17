import AppKit
import SwiftUI

private final class CapturePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class CapturePreviewController {
    private var panel: NSPanel?
    private var dismissal: DispatchWorkItem?
    private var generation = 0
    func refreshLanguage() { panel?.title = L("Capture Preview") }

    static func frame(in visibleFrame: CGRect) -> CGRect {
        CGRect(x: visibleFrame.maxX - 256, y: visibleFrame.minY + 20, width: 236, height: 166)
    }

    func show(_ image: CGImage, screen: NSScreen?, openEditor: @escaping () -> Void) {
        dismiss()
        guard let screen = screen ?? NSScreen.main else { return }
        let panel = CapturePreviewPanel(contentRect: Self.frame(in: screen.visibleFrame),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = L("Capture Preview")
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let current = generation
        panel.contentView = NSHostingView(rootView: CapturePreviewView(image: NSImage(cgImage: image, size: .zero), open: { [weak self] in
            guard let self, self.generation == current else { return }
            self.dismiss()
            openEditor()
        }, close: { [weak self] in self?.dismiss() }, hover: { [weak self] hovering in
            guard let self, self.generation == current else { return }
            self.dismissal?.cancel()
            if !hovering { self.scheduleDismissal() }
        }))
        self.panel = panel
        panel.orderFrontRegardless()
        scheduleDismissal()
    }

    private func scheduleDismissal() {
        dismissal?.cancel()
        let current = generation
        let job = DispatchWorkItem { [weak self] in
            guard let self, self.generation == current else { return }
            self.dismiss()
        }
        dismissal = job
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: job)
    }

    func dismiss() {
        generation += 1
        dismissal?.cancel(); dismissal = nil
        panel?.orderOut(nil); panel?.close(); panel = nil
    }
}

private struct CapturePreviewView: View {
    @ObservedObject private var localization = Localization.shared
    let image: NSImage
    let open: () -> Void
    let close: () -> Void
    let hover: (Bool) -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: open) {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.regularMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.white.opacity(0.7), lineWidth: 1.5))
                    .shadow(color: .black.opacity(0.24), radius: 6, y: 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("Edit Capture"))
            .help(L("Copied · Click to edit"))
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
                    .frame(width: 20, height: 20).background(.regularMaterial, in: Circle())
            }.buttonStyle(.plain).padding(6).opacity(hovering ? 1 : 0)
                .accessibilityLabel(L("Close Preview"))
        }
        .padding(8)
        .onHover { hovering = $0; hover($0) }
    }
}
