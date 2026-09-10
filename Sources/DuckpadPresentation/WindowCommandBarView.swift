import DuckpadLocalization
import AppKit

/// A compact, window-local route into Duckpad's native menu tree.
///
/// Every control opens the original native submenu at an explicit edge below
/// the bar. AppKit validation, state, shortcuts, targets, and actions therefore
/// remain authoritative in the application's native main menu.
@MainActor
public final class WindowCommandBarView: NSVisualEffectView {
    public static let presentedMenuTitles = [
        "File", "Edit", "Search", "View", "Encoding",
        "Language", "Preferences", "Tools", "Plugins", "Window", "Help",
    ]

    public private(set) var menuTitles: [String] = []
    public private(set) var activeMenuTitle: String?

    private var barHeight: NSLayoutConstraint!
    private let stackView = NSStackView()
    private let bottomSeparator = NSBox()
    private var menusByTitle: [String: NSMenu] = [:]
    private var rootItemsByTitle: [String: NSMenuItem] = [:]
    private var buttonsByTitle: [String: NSPopUpButton] = [:]
    private var trackingAreasByTitle: [String: NSTrackingArea] = [:]
    private var hoveredMenuTitle: String?
    private var observesMenuTracking = false
    private var isPresentingMenu = false
    private var pendingMenuTitle: String?
    private var trackingTimer: Timer?
    private var lastTrackingPointer: NSPoint?

    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        material = .headerView
        blendingMode = .withinWindow
        state = .followsWindowActiveState
        // A native separator stays above the visual-effect material and
        // resolves its color in this window's effective appearance.
        bottomSeparator.boxType = .separator
        bottomSeparator.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bottomSeparator)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("duckpad.window.command-bar")
        setAccessibilityLabel(L10n.text("Application commands"))

        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .gravityAreas
        stackView.spacing = 2 * 1.3
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 5, bottom: 0, right: 5)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stackView)
        barHeight = heightAnchor.constraint(equalToConstant: 27)
        NSLayoutConstraint.activate([
            barHeight,
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            stackView.topAnchor.constraint(equalTo: topAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            bottomSeparator.leadingAnchor.constraint(equalTo: leadingAnchor),
            bottomSeparator.trailingAnchor.constraint(equalTo: trailingAnchor),
            bottomSeparator.bottomAnchor.constraint(equalTo: bottomAnchor),
            bottomSeparator.heightAnchor.constraint(equalToConstant: 1),
        ])
        applyAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func setBarVisible(_ visible: Bool) {
        if !visible { dismissMenu() }
        barHeight.constant = visible ? 27 : 0
        isHidden = !visible
    }

    public func apply(mainMenu: NSMenu) {
        dismissMenu()
        removeMenuButtons()
        startObservingMenuTracking()
        let available: [String: (NSMenuItem, NSMenu)] = Dictionary(
            uniqueKeysWithValues: mainMenu.items.compactMap {
                item -> (String, (NSMenuItem, NSMenu))? in
                guard let submenu = item.submenu, !submenu.title.isEmpty else { return nil }
                return (item.identifier?.rawValue ?? submenu.title, (item, submenu))
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
        pendingMenuTitle = nil
        guard let title = activeMenuTitle else { return }
        menusByTitle[title]?.cancelTracking()
        setActiveMenuTitle(nil)
    }

    public func tearDown() {
        dismissMenu()
        stopPointerTracking()
        removeMenuButtons()
        stopObservingMenuTracking()
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
        switchTrackingMenu(to: title)
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
        let button = WindowCommandMenuButton(frame: .zero, pullsDown: true)
        let itemVisibility = menu.items.map(\.isHidden)
        button.menu = menu
        for (item, wasHidden) in zip(menu.items, itemVisibility) {
            item.isHidden = wasHidden
        }
        if let cell = button.cell as? NSPopUpButtonCell {
            cell.usesItemFromMenu = false
            cell.menuItem = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
            cell.arrowPosition = .noArrow
        }
        button.identifier = NSUserInterfaceItemIdentifier(title)
        button.target = self
        button.action = #selector(showMenu(_:))
        button.bezelStyle = .inline
        button.isBordered = false
        button.controlSize = .small
        button.font = .menuBarFont(ofSize: 13)
        button.wantsLayer = true
        button.layer?.cornerRadius = 7
        button.setAccessibilityRole(.popUpButton)
        button.setAccessibilityIdentifier("duckpad.window.command.\(title.lowercased())")
        button.setAccessibilityLabel(L10n.text("%1$@ menu", L10n.argument(menu.title)))
        button.setAccessibilityHelp(L10n.text("Show the %1$@ menu", L10n.argument(menu.title)))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(equalToConstant: 23).isActive = true
        applyVisualState(to: button, title: title)
        return button
    }

    @objc private func showMenu(_ sender: NSButton) {
        guard !isPresentingMenu, sender.isEnabled else { return }
        isPresentingMenu = true
        startPointerTracking()
        defer {
            isPresentingMenu = false
            pendingMenuTitle = nil
            stopPointerTracking()
            setActiveMenuTitle(nil)
            synchronizeHoverWithPointer()
        }
        var nextTitle: String? = sender.identifier?.rawValue
        while let title = nextTitle, let button = buttonsByTitle[title],
              button.isEnabled, let menu = prepareMenuForPresentation(named: title) {
            pendingMenuTitle = nil
            let buttonFrame = button.convert(button.bounds, to: self)
            menu.popUp(
                positioning: nil,
                at: NSPoint(x: buttonFrame.minX, y: bounds.minY - 1),
                in: self
            )
            nextTitle = pendingMenuTitle
        }
    }

    // NSMenu runs its own event-tracking loop, where view mouseEntered events
    // aren't reliably delivered. Poll only during that short native menu session.
    private func startPointerTracking() {
        lastTrackingPointer = window?.mouseLocationOutsideOfEventStream
        let timer = Timer(timeInterval: 1 / 60, target: self,
                          selector: #selector(pollMenuPointer), userInfo: nil, repeats: true)
        trackingTimer = timer
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func stopPointerTracking() {
        trackingTimer?.invalidate()
        trackingTimer = nil
        lastTrackingPointer = nil
    }

    @objc private func pollMenuPointer() {
        guard let window else { dismissMenu(); return }
        trackMenuPointer(at: window.mouseLocationOutsideOfEventStream)
    }

    func trackMenuPointer(at point: NSPoint) {
        guard point != lastTrackingPointer else { return }
        lastTrackingPointer = point
        guard let title = menuTitles.first(where: { title in
            guard let button = buttonsByTitle[title], button.isEnabled,
                  !button.isHiddenOrHasHiddenAncestor else { return false }
            let local = button.convert(point, from: nil)
            return button.bounds.contains(local) && button.visibleRect.contains(local)
        }) else { return }
        setHoveredMenuTitle(title)
        switchTrackingMenu(to: title)
    }

    private func switchTrackingMenu(to title: String) {
        guard isPresentingMenu, let activeMenuTitle,
              activeMenuTitle != title, pendingMenuTitle != title,
              buttonsByTitle[title]?.isEnabled == true else { return }
        pendingMenuTitle = title
        menusByTitle[activeMenuTitle]?.cancelTrackingWithoutAnimation()
    }

    private func startObservingMenuTracking() {
        guard !observesMenuTracking else { return }
        observesMenuTracking = true
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
        button.needsDisplay = true
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
        layer?.backgroundColor = NSColor.clear.cgColor
        for title in menuTitles {
            guard let button = buttonsByTitle[title] else { continue }
            applyVisualState(to: button, title: title)
        }
    }
}
