import AppKit

/// A compact, window-local route into Duckpad's native menu tree.
///
/// The bar deliberately retains the original submenus instead of copying menu
/// items. This keeps AppKit validation, state, shortcuts, targets, and actions
/// authoritative in one place: the application's native main menu.
@MainActor
public final class WindowCommandBarView: NSView {
    public static let presentedMenuTitles = [
        "File", "Edit", "Search", "View", "Format",
        "Language", "Tabs", "Extensions", "Window",
    ]

    public private(set) var menuTitles: [String] = []
    public private(set) var activeMenuTitle: String?

    private let stackView = NSStackView()
    private let bottomSeparator = CALayer()
    private var menusByTitle: [String: NSMenu] = [:]
    private var buttonsByTitle: [String: NSButton] = [:]

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.addSublayer(bottomSeparator)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("duckpad.window.command-bar")
        setAccessibilityLabel("Application commands")

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .gravityAreas
        stackView.spacing = 1
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 6, bottom: 0, right: 6)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 27),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func apply(mainMenu: NSMenu) {
        dismissMenu()
        removeMenuButtons()
        let available: [String: NSMenu] = Dictionary(
            uniqueKeysWithValues: mainMenu.items.compactMap { item -> (String, NSMenu)? in
            guard let submenu = item.submenu, !submenu.title.isEmpty else { return nil }
            return (submenu.title, submenu)
            }
        )
        for title in Self.presentedMenuTitles {
            guard let menu = available[title] else { continue }
            let button = makeButton(title: title)
            menusByTitle[title] = menu
            buttonsByTitle[title] = button
            menuTitles.append(title)
            stackView.addArrangedSubview(button)
        }
    }

    public func menu(named title: String) -> NSMenu? { menusByTitle[title] }

    public func button(named title: String) -> NSButton? { buttonsByTitle[title] }

    @discardableResult
    public func prepareMenuForPresentation(named title: String) -> NSMenu? {
        guard let menu = menusByTitle[title] else { return nil }
        dismissMenu()
        activeMenuTitle = title
        menu.update()
        return menu
    }

    public func dismissMenu() {
        guard let title = activeMenuTitle else { return }
        menusByTitle[title]?.cancelTracking()
        activeMenuTitle = nil
    }

    public func tearDown() {
        dismissMenu()
        removeMenuButtons()
    }

    public override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let thickness = 1 / scale
        bottomSeparator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thickness)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func makeButton(title: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(showMenu(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .regular)
        button.contentTintColor = .labelColor
        button.setAccessibilityRole(.popUpButton)
        button.setAccessibilityIdentifier("duckpad.window.command.\(title.lowercased())")
        button.setAccessibilityLabel("\(title) menu")
        button.setAccessibilityHelp("Show the \(title) menu")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 25).isActive = true
        return button
    }

    @objc private func showMenu(_ sender: NSButton) {
        let title = sender.title
        guard let menu = prepareMenuForPresentation(named: title) else { return }
        let point = NSPoint(x: 0, y: sender.bounds.minY - 1)
        menu.popUp(positioning: nil, at: point, in: sender)
        if activeMenuTitle == title { activeMenuTitle = nil }
    }

    private func removeMenuButtons() {
        for button in buttonsByTitle.values {
            stackView.removeArrangedSubview(button)
            button.removeFromSuperview()
            button.target = nil
            button.action = nil
        }
        menuTitles.removeAll(keepingCapacity: true)
        menusByTitle.removeAll(keepingCapacity: true)
        buttonsByTitle.removeAll(keepingCapacity: true)
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        bottomSeparator.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.62).cgColor
    }
}
