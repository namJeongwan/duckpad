import DuckpadLocalization
import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
public final class EditorGroupPaneView: NSView {
    public let groupID: EditorGroupID
    public let tabStrip: MultilineTabStripView
    public let editorHostView: NSView
    public private(set) var isFocused = false
    public private(set) var focusUpdateCount = 0

    public init(
        groupID: EditorGroupID,
        editorHostView: NSView,
        tabStrip: MultilineTabStripView = MultilineTabStripView(frame: .zero)
    ) {
        self.groupID = groupID
        self.editorHostView = editorHostView
        self.tabStrip = tabStrip
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.borderWidth = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("duckpad.editor-group.\(groupID.rawValue)")
        setAccessibilityLabel(L10n.text("%1$@ editor group", L10n.text(groupID.rawValue.capitalized)))

        tabStrip.setEditorGroupID(groupID)
        tabStrip.hostedCollectionView.setAccessibilityLabel(
            L10n.text("%1$@ editor group tabs", L10n.text(groupID.rawValue.capitalized))
        )
        tabStrip.hostedCollectionView.setAccessibilityIdentifier(
            "duckpad.editor-group.\(groupID.rawValue).tabs"
        )
        editorHostView.translatesAutoresizingMaskIntoConstraints = false
        editorHostView.removeFromSuperview()
        addSubview(tabStrip)
        addSubview(editorHostView)
        NSLayoutConstraint.activate([
            tabStrip.leadingAnchor.constraint(equalTo: leadingAnchor),
            tabStrip.trailingAnchor.constraint(equalTo: trailingAnchor),
            tabStrip.topAnchor.constraint(equalTo: topAnchor),
            editorHostView.leadingAnchor.constraint(equalTo: leadingAnchor),
            editorHostView.trailingAnchor.constraint(equalTo: trailingAnchor),
            editorHostView.topAnchor.constraint(equalTo: tabStrip.bottomAnchor),
            editorHostView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    public func apply(tabs: [TabSnapshot], selectedTabID: TabID?, focused: Bool) {
        let selectedTabs = tabs.map { tab in
            TabSnapshot(
                id: tab.id,
                title: tab.title,
                isActive: tab.id == selectedTabID,
                isDirty: tab.isDirty,
                isPinned: tab.isPinned,
                buffer: tab.buffer,
                fullPath: tab.fullPath
            )
        }
        tabStrip.apply(tabs: selectedTabs)
        setFocused(focused)
    }

    public func setFocused(_ focused: Bool) {
        guard isFocused != focused else {
            setAccessibilityValue(focused ? L10n.text("focused") : L10n.text("not focused"))
            return
        }
        isFocused = focused
        focusUpdateCount += 1
        setAccessibilityValue(focused ? L10n.text("focused") : L10n.text("not focused"))
    }

    public func tearDown() {
        tabStrip.tearDownHostedViews()
        editorHostView.removeFromSuperview()
    }

    func refreshLocalization(catalog: LocalizationCatalog = L10n.catalog) {
        tabStrip.refreshLocalization(catalog: catalog)
        let group = catalog.text(groupID.rawValue.capitalized)
        setAccessibilityLabel(catalog.text("%1$@ editor group", arguments: [group]))
        setAccessibilityValue(catalog.text(isFocused ? "focused" : "not focused"))
        tabStrip.hostedCollectionView.setAccessibilityLabel(catalog.text("%1$@ editor group tabs", arguments: [group]))
    }

}
