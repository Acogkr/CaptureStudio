import AppKit

// The pasteboard owns an immutable, flattened image snapshot. Encoding is lazy,
// so drawing or moving a mark doesn't encode a full PNG on every mouse-up.
private final class ImageClipboardProvider: NSObject, NSPasteboardItemDataProvider {
    private let state: EditState
    private let lock = NSRecursiveLock()
    private var rendered: CGImage?
    private var encoded: [NSPasteboard.PasteboardType: Data] = [:]
    var onFailure: (() -> Void)?

    init(state: EditState) { self.state = state }

    func data(for type: NSPasteboard.PasteboardType) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        if let data = encoded[type] { return data }
        let image = try rendered ?? ImageRenderer.render(state)
        rendered = image
        let data: Data
        if type == .png { data = try ImageRenderer.png(image) }
        else if type == .tiff, let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation { data = tiff }
        else { throw EditorError.render }
        encoded[type] = data
        return data
    }

    func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem,
                    provideDataForType type: NSPasteboard.PasteboardType) {
        do { item.setData(try data(for: type), forType: type) }
        catch { onFailure?() }
    }
}

@MainActor
final class ImageClipboard {
    private let pasteboard: NSPasteboard
    private var provider: ImageClipboardProvider?
    private var item: NSPasteboardItem?
    private var ownedChangeCount: Int?
    var onFailure: (() -> Void)?

    init(pasteboard: NSPasteboard = .general) { self.pasteboard = pasteboard }

    @discardableResult
    func publish(_ state: EditState) -> Bool {
        let nextProvider = ImageClipboardProvider(state: state)
        nextProvider.onFailure = { [weak self] in
            DispatchQueue.main.async { [weak self] in self?.onFailure?() }
        }
        let nextItem = NSPasteboardItem()
        guard nextItem.setDataProvider(nextProvider, forTypes: [.png, .tiff]) else { return false }
        pasteboard.clearContents()
        guard pasteboard.writeObjects([nextItem]) else { return false }
        provider = nextProvider; item = nextItem
        ownedChangeCount = pasteboard.changeCount
        return true
    }

    // Keep the last image usable after quitting, but never reclaim a clipboard
    // the user has since replaced in another app or in a text field.
    @discardableResult
    func finish() -> Bool {
        guard let ownedChangeCount, pasteboard.changeCount == ownedChangeCount,
              let provider, let item else { return true }
        do {
            let png = try provider.data(for: .png)
            let tiff = try provider.data(for: .tiff)
            return item.setData(png, forType: .png) && item.setData(tiff, forType: .tiff)
        } catch { return false }
    }
}
