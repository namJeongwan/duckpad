import AppKit
import DuckpadLocalization

@MainActor
final class SearchWindowAppearanceView: NSView {
    var onChange: (() -> Void)?
    private let enabled = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let inactive = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let always = NSButton(radioButtonWithTitle: "", target: nil, action: nil)
    private let slider = SearchOpacitySlider(frame: .zero)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        inactive.state = .on
        for (control, identifier) in [(enabled, "enabled"), (inactive, "inactive"), (always, "always")] {
            control.controlSize = .small
            control.font = .systemFont(ofSize: 11)
            control.target = self
            control.action = #selector(changed(_:))
            control.setAccessibilityIdentifier("duckpad.search.opacity." + identifier)
        }
        slider.onTrackingChange = { [weak self] in self?.onChange?() }
        slider.controlSize = .small
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed(_:))
        slider.setAccessibilityIdentifier("duckpad.search.opacity.value")
        let choices = NSStackView(views: [inactive, always])
        choices.orientation = .horizontal
        choices.spacing = 8
        let stack = NSStackView(views: [enabled, choices, slider])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        let box = NSBox()
        box.boxType = .primary
        box.titlePosition = .noTitle
        box.contentViewMargins = NSSize(width: 8, height: 6)
        box.translatesAutoresizingMaskIntoConstraints = false
        addSubview(box)
        let content = NSView()
        box.contentView = content
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            box.leadingAnchor.constraint(equalTo: leadingAnchor),
            box.trailingAnchor.constraint(equalTo: trailingAnchor),
            box.topAnchor.constraint(equalTo: topAnchor),
            box.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            slider.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        refreshLocalization()
        changed(enabled)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        enabled.title = catalog.text("Transparency")
        inactive.title = catalog.text("When inactive")
        always.title = catalog.text("Always")
        slider.setAccessibilityLabel(catalog.text("Window opacity"))
    }

    func windowAlpha(isKeyWindow: Bool) -> CGFloat {
        guard !slider.isAdjustingOpacity, enabled.state == .on, always.state == .on || !isKeyWindow else { return 1 }
        return CGFloat(max(0.5, min(1, slider.doubleValue)))
    }

    @objc private func changed(_ sender: NSControl) {
        if sender === inactive || sender === always {
            inactive.state = sender === inactive ? .on : .off
            always.state = sender === always ? .on : .off
        }
        for control in [inactive, always, slider] as [NSControl] { control.isEnabled = enabled.state == .on }
        onChange?()
    }
}
