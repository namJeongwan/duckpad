import AppKit

struct ShortcutIdentity: Hashable {
    let key: String
    let modifiers: NSEvent.ModifierFlags.RawValue
}

/// Strict, deterministic subset of the extension manifest key grammar.
/// Plain typing shortcuts are rejected; an extension must include Command,
/// Control, or Option and can never silently steal ordinary editor input.
struct MenuShortcut {
    let keyEquivalent: String
    let modifiers: NSEvent.ModifierFlags
    let accessibilityLabel: String

    var identity: ShortcutIdentity {
        ShortcutIdentity(
            key: keyEquivalent.lowercased(),
            modifiers: modifiers.intersection([.command, .control, .option, .shift]).rawValue
        )
    }

    static func display(key: String, modifiers: NSEvent.ModifierFlags) -> String {
        guard !key.isEmpty else { return "" }
        let label: String
        switch key {
        case String(UnicodeScalar(NSUpArrowFunctionKey)!): label = "↑"
        case String(UnicodeScalar(NSDownArrowFunctionKey)!): label = "↓"
        case String(UnicodeScalar(NSLeftArrowFunctionKey)!): label = "←"
        case String(UnicodeScalar(NSRightArrowFunctionKey)!): label = "→"
        case "\t": label = "⇥"
        case "\r": label = "↩"
        case "\u{1b}": label = "⎋"
        case " ": label = "␣"
        default:
            if let scalar = key.unicodeScalars.first, (NSF1FunctionKey...NSF20FunctionKey).contains(Int(scalar.value)) {
                label = "F\(Int(scalar.value) - NSF1FunctionKey + 1)"
            } else { label = key.uppercased() }
        }
        return (modifiers.contains(.control) ? "⌃" : "") + (modifiers.contains(.option) ? "⌥" : "") +
            (modifiers.contains(.shift) ? "⇧" : "") + (modifiers.contains(.command) ? "⌘" : "") + label
    }

    init?(_ declaration: String) {
        let tokens = declaration.split(separator: "+", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard tokens.count >= 2, tokens.allSatisfy({ !$0.isEmpty }) else { return nil }

        var modifiers: NSEvent.ModifierFlags = []
        var modifierNames: [String] = []
        var keyToken: String?
        for token in tokens {
            let parsed: (NSEvent.ModifierFlags, String)? = switch token {
            case "cmd", "command": (.command, "Command")
            case "ctrl", "control": (.control, "Control")
            case "opt", "option", "alt": (.option, "Option")
            case "shift": (.shift, "Shift")
            default: nil
            }
            if let parsed {
                guard !modifiers.contains(parsed.0) else { return nil }
                modifiers.insert(parsed.0)
                modifierNames.append(parsed.1)
            } else {
                guard keyToken == nil else { return nil }
                keyToken = token
            }
        }
        guard modifiers.contains(.command) || modifiers.contains(.control) || modifiers.contains(.option),
              let keyToken,
              let key = Self.key(for: keyToken)
        else { return nil }
        self.keyEquivalent = key.value
        self.modifiers = modifiers
        self.accessibilityLabel = (modifierNames + [key.label]).joined(separator: "-")
    }

    private static func key(for token: String) -> (value: String, label: String)? {
        if token.count == 1,
           let scalar = token.unicodeScalars.first,
           scalar.isASCII,
           (0x21...0x7E).contains(scalar.value) {
            return (token, token.uppercased())
        }
        switch token {
        case "space": return (" ", "Space")
        case "tab": return ("\t", "Tab")
        case "return", "enter": return ("\r", "Return")
        case "escape", "esc": return ("\u{1b}", "Escape")
        case "up": return (String(UnicodeScalar(NSUpArrowFunctionKey)!), "Up Arrow")
        case "down": return (String(UnicodeScalar(NSDownArrowFunctionKey)!), "Down Arrow")
        case "left": return (String(UnicodeScalar(NSLeftArrowFunctionKey)!), "Left Arrow")
        case "right": return (String(UnicodeScalar(NSRightArrowFunctionKey)!), "Right Arrow")
        default:
            guard token.first == "f",
                  let number = Int(token.dropFirst()),
                  (1...20).contains(number),
                  let scalar = UnicodeScalar(NSF1FunctionKey + number - 1)
            else { return nil }
            return (String(scalar), "F\(number)")
        }
    }
}
