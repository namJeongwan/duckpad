import AppKit
import DuckpadLocalization

@MainActor
final class MaterialFileIconTheme {
    static let shared = MaterialFileIconTheme()

    private struct Manifest: Decodable {
        struct IconDefinition: Decodable { let iconPath: String }
        struct AppearanceOverrides: Decodable { let fileExtensions: [String: String]? }

        let iconDefinitions: [String: IconDefinition]
        let fileExtensions: [String: String]
        let light: AppearanceOverrides?
        let file: String
    }

    private let manifestDirectory: URL?
    private let iconPaths: [String: String]
    private let fileExtensions: [String: String]
    private let lightFileExtensions: [String: String]
    private let fallbackName: String
    private var images: [String: NSImage] = [:]

    private init() {
        let bundle = Self.resourceBundle
        guard let manifestURL = bundle.url(
            forResource: "material-icons",
            withExtension: "json",
            subdirectory: "MaterialIconTheme/dist"
        ),
        let manifest = try? JSONDecoder().decode(
            Manifest.self,
            from: Data(contentsOf: manifestURL)
        ) else {
            manifestDirectory = nil
            iconPaths = [:]
            fileExtensions = [:]
            lightFileExtensions = [:]
            fallbackName = "file"
            return
        }
        manifestDirectory = manifestURL.deletingLastPathComponent()
        iconPaths = manifest.iconDefinitions.mapValues { $0.iconPath }
        fileExtensions = Self.lowercasedKeys(manifest.fileExtensions)
        lightFileExtensions = Self.lowercasedKeys(manifest.light?.fileExtensions ?? [:])
        fallbackName = manifest.file
    }

    func icon(
        for fileName: String,
        appearance: NSAppearance
    ) -> (name: String, image: NSImage) {
        let requestedName = iconName(for: fileName, appearance: appearance)
        if let image = image(named: requestedName) {
            return (requestedName, image)
        }
        if let image = image(named: fallbackName) {
            return (fallbackName, image)
        }
        return (
            fallbackName,
            NSImage(systemSymbolName: "doc", accessibilityDescription: L10n.text("File")) ?? NSImage()
        )
    }

    private func iconName(for fileName: String, appearance: NSAppearance) -> String {
        let name = URL(fileURLWithPath: fileName).lastPathComponent.lowercased()
        let usesLightIcons = appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
        var searchStart = name.startIndex
        while let dot = name[searchStart...].firstIndex(of: ".") {
            let suffixStart = name.index(after: dot)
            guard suffixStart < name.endIndex else { break }
            let suffix = String(name[suffixStart...])
            if let baseName = fileExtensions[suffix] {
                return usesLightIcons ? lightFileExtensions[suffix] ?? baseName : baseName
            }
            searchStart = suffixStart
        }
        return fallbackName
    }

    private func image(named name: String) -> NSImage? {
        if let image = images[name] { return image }
        guard let manifestDirectory,
              let relativePath = iconPaths[name],
              let image = NSImage(contentsOf: URL(
                  fileURLWithPath: relativePath,
                  relativeTo: manifestDirectory
              ).standardizedFileURL) else { return nil }
        image.isTemplate = false
        images[name] = image
        return image
    }

    private static func lowercasedKeys(_ values: [String: String]) -> [String: String] {
        values.keys.sorted().reduce(into: [:]) { result, key in
            result[key.lowercased()] = values[key]
        }
    }

    private static var resourceBundle: Bundle {
        if let resources = Bundle.main.resourceURL,
           let packaged = Bundle(
               url: resources.appendingPathComponent(
                   "Duckpad_DuckpadPresentation.bundle",
                   isDirectory: true
               )
           ) {
            return packaged
        }
        return Bundle.module
    }
}
