import AppKit

@MainActor
final class FileDropView: NSView {
    var onFiles: (([URL]) -> Void)?
    var onFilesAtLocation: (([URL], NSPoint) -> Void)?
    var onFolders: (([URL]) -> Void)?
    var onEffectiveAppearanceChange: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onEffectiveAppearanceChange?()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard sender.draggingSourceOperationMask.contains(.copy) else { return [] }
        let content = partition(fileURLs(from: sender))
        return ((onFiles != nil || onFilesAtLocation != nil) && !content.files.isEmpty)
            || (onFolders != nil && !content.folders.isEmpty) ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        !draggingEntered(sender).isEmpty
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard prepareForDragOperation(sender) else { return false }
        let urls = fileURLs(from: sender)
        guard !urls.isEmpty else { return false }
        let content = partition(urls)
        var handled = false
        if let onFilesAtLocation, !content.files.isEmpty {
            onFilesAtLocation(content.files, sender.draggingLocation)
            handled = true
        } else if let onFiles, !content.files.isEmpty {
            onFiles(content.files)
            handled = true
        }
        if let onFolders, !content.folders.isEmpty {
            onFolders(content.folders)
            handled = true
        }
        return handled
    }

    private func partition(_ urls: [URL]) -> (files: [URL], folders: [URL]) {
        var files: [URL] = []
        var folders: [URL] = []
        for url in urls {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue {
                folders.append(url)
            } else {
                files.append(url)
            }
        }
        return (files, folders)
    }

    private func fileURLs(from sender: any NSDraggingInfo) -> [URL] {
        (sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }
}
