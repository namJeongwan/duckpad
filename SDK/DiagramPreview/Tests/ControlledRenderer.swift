import AppKit

/// Intentionally ignores cancellation so the controller must reject stale replies.
@MainActor final class ControlledRenderer: DiagramRendering {
    let hasRuntimeSettings: Bool
    var pending: CheckedContinuation<DiagramRender, any Error>?
    private(set) var cancellations = 0
    init(settings: Bool) { hasRuntimeSettings = settings }
    func render(_ source: String, dark: Bool, runtimePath: String, install: Bool) async throws -> DiagramRender {
        try await withCheckedThrowingContinuation { pending = $0 }
    }
    func cancel() { cancellations += 1 }
    func succeed() {
        let image = NSImage(size: NSSize(width: 120, height: 80), flipped: false) { bounds in
            NSColor.systemBlue.setFill(); bounds.fill(); return true
        }
        let png = NSBitmapImageRep(data: image.tiffRepresentation!)!.representation(using: .png, properties: [:])!
        let callback = pending; pending = nil
        callback?.resume(returning: DiagramRender(svg: Data("<svg/>".utf8), png: png, width: 120, height: 80))
    }
}
