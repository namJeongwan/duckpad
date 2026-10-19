import AppKit
import Carbon

@MainActor
enum ShortcutRecorder {
    static func declaration(for event: NSEvent) -> String? {
        let mask = event.modifierFlags.intersection([.command, .control, .option, .shift])
        // Option alone belongs to text entry and dead-key composition on macOS.
        guard !mask.intersection([.command, .control]).isEmpty,
              let characters = unmodifiedCharacters(for: event).map({ $0.lowercased() }),
              characters.count == 1 else { return nil }
        let key: String
        switch characters {
        case " ": key = "space"
        case "\t": key = "tab"
        case "\r": key = "return"
        case "\u{1b}": key = "escape"
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): key = "up"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): key = "down"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): key = "left"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): key = "right"
        default:
            if let scalar = characters.unicodeScalars.first, (NSF1FunctionKey...NSF20FunctionKey).contains(Int(scalar.value)) {
                key = "f\(Int(scalar.value) - NSF1FunctionKey + 1)"
            } else { key = characters }
        }
        // These combinations are intercepted by macOS before an application can act.
        if mask == [.command] && ["tab", "space"].contains(key) { return nil }
        if mask == [.command, .option] && key == "escape" { return nil }
        let declaration = [(mask.contains(.control) ? "ctrl" : nil), (mask.contains(.option) ? "alt" : nil),
                           (mask.contains(.shift) ? "shift" : nil), (mask.contains(.command) ? "cmd" : nil), key]
            .compactMap { $0 }.joined(separator: "+")
        return MenuShortcut(declaration) == nil ? nil : declaration
    }
    private static func unmodifiedCharacters(for event: NSEvent) -> String? {
        let special: [UInt16: Int] = [123: NSLeftArrowFunctionKey, 124: NSRightArrowFunctionKey,
            125: NSDownArrowFunctionKey, 126: NSUpArrowFunctionKey,
            122: NSF1FunctionKey, 120: NSF2FunctionKey, 99: NSF3FunctionKey, 118: NSF4FunctionKey,
            96: NSF5FunctionKey, 97: NSF6FunctionKey, 98: NSF7FunctionKey, 100: NSF8FunctionKey,
            101: NSF9FunctionKey, 109: NSF10FunctionKey, 103: NSF11FunctionKey, 111: NSF12FunctionKey,
            105: NSF13FunctionKey, 107: NSF14FunctionKey, 113: NSF15FunctionKey, 106: NSF16FunctionKey,
            64: NSF17FunctionKey, 79: NSF18FunctionKey, 80: NSF19FunctionKey, 90: NSF20FunctionKey]
        if let scalar = special[event.keyCode].flatMap(UnicodeScalar.init) { return String(scalar) }
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else {
            return event.characters(byApplyingModifiers: [])
        }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue()
        guard let bytes = CFDataGetBytePtr(data) else { return nil }
        let layout = UnsafeRawPointer(bytes).assumingMemoryBound(to: UCKeyboardLayout.self)
        var deadKey: UInt32 = 0
        var count = 0
        var characters = [UniChar](repeating: 0, count: 8)
        let status = UCKeyTranslate(layout, event.keyCode, UInt16(kUCKeyActionDown), 0,
            UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKey,
            characters.count, &count, &characters)
        guard status == noErr, count > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: count)
    }

}
