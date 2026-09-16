import Foundation

/// SwiftPM's generated accessor checks beside the executable and the build
/// directory. A distributed macOS app stores resource bundles in Contents/Resources.
enum DuckpadPresentationResources {
    static let bundle = resolve(in: .main)

    static func resolve(in applicationBundle: Bundle) -> Bundle? {
        if let resources = applicationBundle.resourceURL,
           let packaged = Bundle(url: resources.appendingPathComponent(
               "Duckpad_DuckpadPresentation.bundle", isDirectory: true)) {
            return packaged
        }
        // Do not evaluate Bundle.module's fatalError fallback inside a packaged app.
        // Missing assets should produce a preview error or fallback icon, not a crash.
        guard applicationBundle.bundleURL.pathExtension.lowercased() != "app" else { return nil }
        return Bundle.module
    }
}
