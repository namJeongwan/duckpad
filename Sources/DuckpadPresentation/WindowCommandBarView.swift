import AppKit

/// A compact, window-local route into Duckpad's native menu tree.
///
/// Every control is a genuine AppKit pull-down button backed by the original
/// submenu. AppKit validation, state, shortcuts, targets, and actions therefore
/// remain authoritative in the application's native main menu.
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
    private var rootItemsByTitle: [String: NSMenuItem] = [:]
    private var buttonsByTitle: [String: NSPopUpButton] = [:]
    private var trackingAreasByTitle: [String: NSTrackingArea] = [:]
    private var hoveredMenuTitle: String?
    private var observesMenuTracking = false

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
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 5)
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
        startObservingMenuTracking()
        let available: [String: (NSMenuItem, NSMenu)] = Dictionary(
            uniqueKeysWithValues: mainMenu.items.compactMap {
                item -> (String, (NSMenuItem, NSMenu))? in
                guard let submenu = item.submenu, !submenu.title.isEmpty else { return nil }
                return (submenu.title, (item, submenu))
            }
        )
        for title in Self.presentedMenuTitles {
            guard let (rootItem, menu) = available[title] else { continue }
            let button = makeButton(title: title, menu: menu)
            menusByTitle[title] = menu
            rootItemsByTitle[title] = rootItem
            buttonsByTitle[title] = button
            menuTitles.append(title)
            stackView.addArrangedSubview(button)
        }
        updateTrackingAreas()
    }

    public func menu(named title: String) -> NSMenu? { menusByTitle[title] }

    public func button(named title: String) -> NSPopUpButton? { buttonsByTitle[title] }

    @discardableResult
    public func prepareMenuForPresentation(named title: String) -> NSMenu? {
        guard let menu = menusByTitle[title] else { return nil }
        if let activeMenuTitle, activeMenuTitle != title {
            menusByTitle[activeMenuTitle]?.cancelTracking()
        }
        setActiveMenuTitle(title)
        menu.update()
        return menu
    }

    public func dismissMenu() {
        guard let title = activeMenuTitle else { return }
        menusByTitle[title]?.cancelTracking()
        setActiveMenuTitle(nil)
    }

    public func tearDown() {
        dismissMenu()
        removeMenuButtons()
        stopObservingMenuTracking()
    }

    public override func layout() {
        super.layout()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let thickness = 1 / scale
        bottomSeparator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: thickness)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        removeButtonTrackingAreas()
        for (title, button) in buttonsByTitle {
            let area = NSTrackingArea(
                rect: .zero,
                options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited],
                owner: self,
                userInfo: ["menuTitle": title]
            )
            button.addTrackingArea(area)
            trackingAreasByTitle[title] = area
        }
        synchronizeHoverWithPointer()
    }

    public override func mouseEntered(with event: NSEvent) {
        guard let title = event.trackingArea?.userInfo?["menuTitle"] as? String else { return }
        setHoveredMenuTitle(title)
    }

    public override func mouseExited(with event: NSEvent) {
        guard let title = event.trackingArea?.userInfo?["menuTitle"] as? String,
              hoveredMenuTitle == title else { return }
        setHoveredMenuTitle(nil)
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func makeButton(title: String, menu: NSMenu) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: true)
        let itemVisibility = menu.items.map(\.isHidden)
        button.menu = menu
        for (item, wasHidden) in zip(menu.items, itemVisibility) {
            item.isHidden = wasHidden
        }
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.usesItemFromMenu = false
            cell.menuItem = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            cell.arrowPosition = .noArrow
            cell.preferredEdge = .minY
        }
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.font = .systemFont(ofSize: 12, weight: .regular)
        button.wantsLayer = true
        button.layer?.cornerRadius = 5
        button.setAccessibilityRole(.popUpButton)
        button.setAccessibilityIdentifier("duckpad.window.command.\(title.lowercased())")
        button.setAccessibilityLabel("\(title) menu")
        button.setAccessibilityHelp("Show the \(title) menu")
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 23).isActive = true
        applyVisualState(to: button, title: title)
        return button
    }

    private func startObservingMenuTracking() {
        guard !observesMenuTracking else { return }
        observesMenuTracking = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(popUpButtonWillOpen(_:)),
            name: NSPopUpButtonCell.willPopUpNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidBeginTracking(_:)),
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking(_:)),
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
    }

    private func stopObservingMenuTracking() {
        guard observesMenuTracking else { return }
        NotificationCenter.default.removeObserver(
            self,
            name: NSPopUpButtonCell.willPopUpNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSMenu.didBeginTrackingNotification,
            object: nil
        )
        NotificationCenter.default.removeObserver(
            self,
            name: NSMenu.didEndTrackingNotification,
            object: nil
        )
        observesMenuTracking = false
    }

    @objc private func popUpButtonWillOpen(_ notification: Notification) {
        guard let cell = notification.object as? NSPopUpButtonCell,
              let title = buttonsByTitle.first(where: { $0.value.cell === cell })?.key else { return }
        _ = prepareMenuForPresentation(named: title)
    }

    @objc private func menuDidBeginTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              let title = menusByTitle.first(where: { $0.value === menu })?.key else { return }
        setActiveMenuTitle(title)
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu,
              let title = menusByTitle.first(where: { $0.value === menu })?.key,
              activeMenuTitle == title else { return }
        setActiveMenuTitle(nil)
        synchronizeHoverWithPointer()
    }

    private func synchronizeHoverWithPointer() {
        guard let window else {
            setHoveredMenuTitle(nil)
            return
        }
        let pointer = window.mouseLocationOutsideOfEventStream
        let hovered = menuTitles.first { title in
            guard let button = buttonsByTitle[title], !button.isHiddenOrHasHiddenAncestor else {
                return false
            }
            let local = button.convert(pointer, from: nil)
            return button.bounds.contains(local) && button.visibleRect.contains(local)
        }
        setHoveredMenuTitle(hovered)
    }

    private func setHoveredMenuTitle(_ title: String?) {
        guard hoveredMenuTitle != title else { return }
        let previous = hoveredMenuTitle
        hoveredMenuTitle = title
        if let previous, let button = buttonsByTitle[previous] {
            applyVisualState(to: button, title: previous)
        }
        if let title, let button = buttonsByTitle[title] {
            applyVisualState(to: button, title: title)
        }
    }

    private func setActiveMenuTitle(_ title: String?) {
        guard activeMenuTitle != title else { return }
        let previous = activeMenuTitle
        activeMenuTitle = title
        if let previous, let button = buttonsByTitle[previous] {
            applyVisualState(to: button, title: previous)
        }
        if let title, let button = buttonsByTitle[title] {
            applyVisualState(to: button, title: title)
        }
    }

    private func applyVisualState(to button: NSPopUpButton, title: String) {
        let isOpen = activeMenuTitle == title
        let isHovered = hoveredMenuTitle == title
        if isOpen {
            button.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.22).cgColor
            button.contentTintColor = .labelColor
        } else if isHovered {
            button.layer?.backgroundColor = NSColor.selectedControlColor
                .withAlphaComponent(0.16).cgColor
            button.contentTintColor = .labelColor
        } else {
            button.layer?.backgroundColor = NSColor.clear.cgColor
            button.contentTintColor = .secondaryLabelColor
        }
    }

    private func removeButtonTrackingAreas() {
        for (title, area) in trackingAreasByTitle {
            buttonsByTitle[title]?.removeTrackingArea(area)
        }
        trackingAreasByTitle.removeAll(keepingCapacity: true)
    }

    private func removeMenuButtons() {
        setHoveredMenuTitle(nil)
        removeButtonTrackingAreas()
        for (title, button) in buttonsByTitle {
            let menu = menusByTitle[title]
            let itemVisibility = menu?.items.map(\.isHidden) ?? []
            stackView.removeArrangedSubview(button)
            button.removeFromSuperview()
            button.target = nil
            button.action = nil
            button.menu = nil
            if let menu, let rootItem = rootItemsByTitle[title], rootItem.submenu !== menu {
                rootItem.submenu = menu
            }
            if let menu {
                for (item, wasHidden) in zip(menu.items, itemVisibility) {
                    item.isHidden = wasHidden
                }
            }
        }
        menuTitles.removeAll(keepingCapacity: true)
        menusByTitle.removeAll(keepingCapacity: true)
        rootItemsByTitle.removeAll(keepingCapacity: true)
        buttonsByTitle.removeAll(keepingCapacity: true)
    }

    private func applyAppearance() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        bottomSeparator.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.62).cgColor
        for title in menuTitles {
            guard let button = buttonsByTitle[title] else { continue }
            applyVisualState(to: button, title: title)
        }
    }
}
