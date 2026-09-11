import DuckpadLocalization
import AppKit
import DuckpadApplication

public enum EditorNavigationInput {
    public static func lineAndColumn(_ value: String, maximumLine: Int) -> (line: Int, column: Int)? {
        let components = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(omittingEmptySubsequences: false, whereSeparator: { $0 == ":" || $0 == "," })
        guard (1...2).contains(components.count),
              let line = Int(String(components[0]).trimmingCharacters(in: .whitespaces)),
              (1...maximumLine).contains(line) else { return nil }
        let column: Int
        if components.count == 2 {
            guard let parsed = Int(String(components[1]).trimmingCharacters(in: .whitespaces)), parsed > 0 else {
                return nil
            }
            column = parsed
        } else {
            column = 1
        }
        return (line, column)
    }

    public static func utf8Offset(_ value: String, maximumOffset: Int) -> Int? {
        guard let offset = Int(value.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...maximumOffset).contains(offset) else { return nil }
        return offset
    }
}

@MainActor
public protocol EditorNavigationPresenting: AnyObject {
    func presentLineAndColumn(
        current: EditorNavigationPosition,
        in window: NSWindow,
        completion: @escaping @MainActor (Int, Int) -> Void
    )
    func presentUTF8Offset(
        current: EditorNavigationPosition,
        in window: NSWindow,
        completion: @escaping @MainActor (Int) -> Void
    )
}

@MainActor
final class NativeEditorNavigationPresenter: EditorNavigationPresenting {
    private var catalog = L10n.catalog
    private var activeAlerts: [ObjectIdentifier: (alert: NSAlert, title: String, message: String, maximum: Int, accessibility: String)] = [:]

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        self.catalog = catalog
        for entry in activeAlerts.values {
            entry.alert.messageText = catalog.text(entry.title)
            entry.alert.informativeText = catalog.text(entry.message, arguments: [String(entry.maximum)])
            entry.alert.accessoryView?.setAccessibilityLabel(catalog.text(entry.accessibility))
            entry.alert.buttons[0].title = catalog.text("Go")
            entry.alert.buttons[1].title = catalog.text("Cancel")
        }
    }

    func presentLineAndColumn(
        current: EditorNavigationPosition,
        in window: NSWindow,
        completion: @escaping @MainActor (Int, Int) -> Void
    ) {
        present(
            title: "Go to Line / Column",
            message: "Enter line or line:column (1…%1$@).",
            maximum: current.lineCount,
            initialValue: "\(current.line):\(current.column)",
            accessibilityLabel: "Line and column",
            in: window
        ) { value in
            guard let destination = EditorNavigationInput.lineAndColumn(
                value,
                maximumLine: current.lineCount
            ) else { NSSound.beep(); return }
            completion(destination.line, destination.column)
        }
    }

    func presentUTF8Offset(
        current: EditorNavigationPosition,
        in window: NSWindow,
        completion: @escaping @MainActor (Int) -> Void
    ) {
        present(
            title: "Go to UTF-8 Offset",
            message: "Enter a byte offset (0…%1$@).",
            maximum: current.utf8Length,
            initialValue: "\(current.utf8Offset)",
            accessibilityLabel: "UTF-8 byte offset",
            in: window
        ) { value in
            guard let offset = EditorNavigationInput.utf8Offset(
                value,
                maximumOffset: current.utf8Length
            ) else { NSSound.beep(); return }
            completion(offset)
        }
    }

    private func present(
        title: String,
        message: String,
        maximum: Int,
        initialValue: String,
        accessibilityLabel: String,
        in window: NSWindow,
        completion: @escaping @MainActor (String) -> Void
    ) {
        let field = NSTextField(string: initialValue)
        field.frame = NSRect(x: 0, y: 0, width: 280, height: 24)
        field.setAccessibilityLabel(catalog.text(accessibilityLabel))
        field.selectText(nil)

        let alert = NSAlert()
        alert.messageText = catalog.text(title)
        alert.informativeText = catalog.text(message, arguments: [String(maximum)])
        alert.alertStyle = .informational
        alert.accessoryView = field
        alert.addButton(withTitle: catalog.text("Go"))
        alert.addButton(withTitle: catalog.text("Cancel"))
        let identifier = ObjectIdentifier(alert)
        activeAlerts[identifier] = (alert, title, message, maximum, accessibilityLabel)
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.activeAlerts.removeValue(forKey: identifier)
            guard response == .alertFirstButtonReturn else { return }
            MainActor.assumeIsolated { completion(field.stringValue) }
        }
    }
}
