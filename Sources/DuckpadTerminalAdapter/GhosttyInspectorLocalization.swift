import AppKit
import CoreText
import GhosttyKit
import DuckpadLocalization

/// Stable UTF-8 storage for the embedded inspector's C renderer. Both the host
/// language and all strings remain owned by Duckpad's regular localization bundle.
enum GhosttyInspectorLocalization {
    private final class Storage: @unchecked Sendable {
        let lock = NSLock()
        var strings: [String: UnsafeMutablePointer<CChar>] = [:]

        func translated(_ key: UnsafePointer<CChar>) -> UnsafePointer<CChar> {
            let source = String(cString: key)
            let catalog = L10n.catalog
            let value = catalog.text(source)
            guard value != source else { return key }
            let cacheKey = catalog.language.rawValue + "\u{0}" + source
            lock.lock()
            defer { lock.unlock() }
            if let cached = strings[cacheKey] { return UnsafePointer(cached) }
            guard let copy = strdup(value) else { return key }
            strings[cacheKey] = copy
            return UnsafePointer(copy)
        }
    }
    private static let storage = Storage()

    @MainActor static func configure() {
        let language = L10n.catalog.language.rawValue
        let names: [String]
        switch language {
        case "ko": names = ["AppleSDGothicNeo-Regular"]
        case "ja": names = ["HiraginoSans-W3", "AppleSDGothicNeo-Regular"]
        // Modern PingFangUI collections use outlines unsupported by ImGui's
        // stb loader. These system TrueType collections contain Simplified Han.
        case "zh-Hans": names = ["STHeitiSC-Light", "STSongti-SC-Regular"]
        default: names = ["Menlo-Regular"]
        }
        let path = names.lazy.compactMap { name -> String? in
            guard NSFont(name: name, size: 16) != nil else { return nil }
            let font = CTFontCreateWithName(name as CFString, 16, nil)
            return (CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL)?.path
        }.first ?? ""
        path.withCString { fontPath in
            duckpad_inspector_set_translation_callback({ key in
                guard let key else { return nil }
                return GhosttyInspectorLocalization.storage.translated(key)
            }, fontPath)
        }
    }
}
