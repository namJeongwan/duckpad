import AppKit
import GhosttyKit
import DuckpadLocalization

extension GhosttySurfaceView {
    func showSearch(needle: String?) {
        if searchBar == nil {
            let bar = GhosttySearchBar()
            bar.onQuery = { [weak self] query in _ = self?.performBinding("search:" + query) }
            bar.onNavigate = { [weak self] backwards in
                _ = self?.performBinding(backwards ? "navigate_search:previous" : "navigate_search:next")
            }
            bar.onClose = { [weak self] in _ = self?.performBinding("end_search") }
            bar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(bar)
            NSLayoutConstraint.activate([
                bar.topAnchor.constraint(equalTo: topAnchor),
                bar.trailingAnchor.constraint(equalTo: trailingAnchor),
                bar.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
                bar.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.75),
                bar.heightAnchor.constraint(equalToConstant: 32),
            ])
            searchBar = bar
        }
        if let needle { searchBar?.field.stringValue = needle }
        searchBar?.field.selectText(nil)
        if let query = searchBar?.field.stringValue { _ = performBinding("search:" + query) }
    }

    func hideSearch() {
        guard searchBar != nil else { return }
        searchBar?.removeFromSuperview()
        searchBar = nil
        window?.makeFirstResponder(self)
    }

    func updateSearchCount() {
        let locale = L10n.catalog.locale
        searchBar?.count.stringValue = "\(max(0, searchSelected + 1).formatted(.number.locale(locale)))/\(max(0, searchTotal).formatted(.number.locale(locale)))"
    }

    func confirmPaste(_ text: String, state: UnsafeMutableRawPointer) {
        // Ghostty requests this for unsafe multiline/bracketed paste, not ordinary text.
        guard let surface else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("Paste into terminal?")
        alert.informativeText = L10n.text("This text may execute commands in the shell.")
        alert.addButton(withTitle: L10n.text("Paste"))
        alert.addButton(withTitle: L10n.text("Cancel"))
        let accepted = alert.runModal() == .alertFirstButtonReturn
        (accepted ? text : "").withCString { ghostty_surface_complete_clipboard_request(surface, $0, state, true) }
    }
}
