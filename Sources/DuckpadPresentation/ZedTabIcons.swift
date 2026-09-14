import AppKit

@MainActor
enum ZedTabIcons {
    static let pin = load("pin")
    static let unpin = load("unpin")
    static let markdownPreview = load("eye")

    private static func load(_ name: String) -> NSImage? {
        guard let url = DuckpadPresentationResources.bundle?.url(forResource: name, withExtension: "svg", subdirectory: "ZedIcons"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 16, height: 16)
        return image
    }
}
