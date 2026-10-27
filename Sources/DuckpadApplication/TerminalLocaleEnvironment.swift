import Foundation
import Darwin

/// Carry shell locale settings across the XPC boundary without copying the
/// application's entire environment (tokens, loader flags, and other state).
public enum TerminalLocaleEnvironment {
    public static let keys = [
        "LANG", "LANGUAGE", "LC_ALL", "LC_CTYPE", "LC_COLLATE", "LC_MESSAGES",
        "LC_MONETARY", "LC_NUMERIC", "LC_TIME"
    ]

    public static func values(
        inherited: [String: String] = ProcessInfo.processInfo.environment,
        systemLocaleIdentifier: String = Locale.current.identifier
    ) -> [String: String] {
        var result = inherited.filter {
            keys.contains($0.key) && !$0.value.isEmpty && $0.value.utf8.count < 4096 && !$0.value.contains("\0")
        }
        if result["LANG"] == nil {
            let identifier = systemLocaleIdentifier.split(separator: "@").first.map(String.init) ?? ""
            let candidate = identifier.replacingOccurrences(of: "-", with: "_") + ".UTF-8"
            if let locale = newlocale(1 << LC_CTYPE, candidate, nil) {
                freelocale(locale)
                result["LANG"] = candidate
            } else { result["LANG"] = "en_US.UTF-8" }
        }
        return result
    }
}
