import AppKit
import DuckpadApplication
import DuckpadLocalization

@MainActor
final class PersistenceErrorBanner: NSView, PersistenceErrorPresenting {
    private let message = NSTextField(labelWithString: "")
    private var displayedFailure: PersistenceFailure?
    private let retryButton = NSButton(title: L10n.text("Retry"), target: nil, action: nil)
    private var retryAction: (@MainActor () -> Void)?
    private var heightConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.14).cgColor
        isHidden = true
        translatesAutoresizingMaskIntoConstraints = false
        message.lineBreakMode = .byTruncatingTail
        message.translatesAutoresizingMaskIntoConstraints = false
        retryButton.target = self
        retryButton.action = #selector(retryPressed)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(message)
        addSubview(retryButton)
        heightConstraint = heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            heightConstraint,
            message.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            message.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.leadingAnchor.constraint(greaterThanOrEqualTo: message.trailingAnchor, constant: 8),
            retryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            retryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        setAccessibilityIdentifier("duckpad.persistence.error")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func present(failure: PersistenceFailure, retry: @escaping @MainActor () -> Void) {
        displayedFailure = failure
        message.stringValue = L10n.text("Session %1$@ failed: %2$@", L10n.text(failure.operation == .load ? "Restore" : "Save"), PresentationErrorText.message(failure.cause))
        retryAction = retry
        heightConstraint.constant = 36
        isHidden = false
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        retryButton.title = catalog.text("Retry")
        if let failure = displayedFailure {
            message.stringValue = catalog.text("Session %1$@ failed: %2$@", arguments: [
                catalog.text(failure.operation == .load ? "Restore" : "Save"),
                PresentationErrorText.message(failure.cause, catalog: catalog)
            ])
        }
    }

    @objc private func retryPressed() {
        isHidden = true
        heightConstraint.constant = 0
        retryAction?()
    }
}
