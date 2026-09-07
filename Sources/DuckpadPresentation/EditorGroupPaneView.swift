import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
public final class EditorGroupPaneView: NSView {
    public let groupID: EditorGroupID
    public let tabStrip: MultilineTabStripView
    public let editorHostView: NSView
    public private(set) var isFocused = false

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
        layer?.borderWidth = 1
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("duckpad.editor-group.\(groupID.rawValue)")
        setAccessibilityLabel(groupID == .primary ? "Primary editor group" : "Secondary editor group")

        tabStrip.setEditorGroupID(groupID)
        tabStrip.hostedCollectionView.setAccessibilityLabel(
            groupID == .primary ? "Primary editor group tabs" : "Secondary editor group tabs"
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
        applyFocusAppearance()
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
        isFocused = focused
        setAccessibilityValue(focused ? "focused" : "not focused")
        applyFocusAppearance()
    }

    public func tearDown() {
        tabStrip.tearDownHostedViews()
        editorHostView.removeFromSuperview()
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFocusAppearance()
    }

    private func applyFocusAppearance() {
        layer?.borderColor = (isFocused
            ? NSColor.controlAccentColor.withAlphaComponent(0.58)
            : NSColor.separatorColor.withAlphaComponent(0.30)).cgColor
    }
}
