import Foundation

/// Validate keystrokes and paste before they enter the native field editor.
final class FontSizeFormatter: Formatter {
    override func string(for obj: Any?) -> String? { obj as? String }

    override func getObjectValue(_ obj: AutoreleasingUnsafeMutablePointer<AnyObject?>?, for string: String,
                                 errorDescription error: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        guard Self.accepts(string) else { return false }
        obj?.pointee = string as NSString
        return true
    }

    override func isPartialStringValid(_ partialString: String,
                                      newEditingString: AutoreleasingUnsafeMutablePointer<NSString?>?,
                                      errorDescription: AutoreleasingUnsafeMutablePointer<NSString?>?) -> Bool {
        Self.accepts(partialString)
    }

    static func accepts(_ string: String) -> Bool {
        string.utf8.allSatisfy { (48...57).contains($0) || $0 == 46 } && string.filter { $0 == "." }.count <= 1
    }
}
