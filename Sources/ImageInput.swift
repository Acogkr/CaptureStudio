import AppKit

enum ImageInput {
    static func read(_ pasteboard: NSPasteboard) throws -> (CGImage, String) {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            guard urls.count == 1 else { throw InputError.oneImage }
            return (try ImageRenderer.load(urls[0]), urls[0].deletingPathExtension().lastPathComponent)
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff, .init("public.jpeg"), .init("public.heic")] {
            if let data = pasteboard.data(forType: type) { return (try ImageRenderer.load(data), L("Pasted Image")) }
        }
        throw InputError.empty
    }
}
enum InputError: LocalizedError {
    case empty, oneImage
    var errorDescription: String? {
        switch self {
        case .empty: return L("No image on the clipboard. Copy a photo or image file first.")
        case .oneImage: return L("Open one image at a time.")
        }
    }
}
