import AppKit
import GhosttyKit
import DuckpadApplication
import DuckpadPresentation
import DuckpadLocalization

/// AppKit input follows Ghostty's NSTextInputClient preedit/commit ordering.
/// See Vendor/Ghostty/PROVENANCE.md for the upstream implementation and license.
@MainActor
final class GhosttySurfaceView: TerminalSurfaceView, @preconcurrency NSTextInputClient {
    let runtime: GhosttyRuntime
    private let configuration: ShellLaunchConfiguration
    private(set) var surface: ghostty_surface_t?
    private let host = TerminalHostConnection()
    private var launchTask: Task<Void, Never>?
    private var exited = false
    private var stopped = false
    private var marked = NSAttributedString(string: "")
    private var selection = NSRange(location: 0, length: 0)
    private var keyText: [String]?
    var searchBar: GhosttySearchBar?
    var searchTotal = 0 { didSet { updateSearchCount() } }
    var searchSelected = -1 { didSet { updateSearchCount() } }
    var inspectorController: GhosttyInspectorController?
    private var tracking: NSTrackingArea?
    private var geometryUpdatePending = false
    private weak var observedWindow: NSWindow?

    init(runtime: GhosttyRuntime, configuration: ShellLaunchConfiguration) {
        self.runtime = runtime
        self.configuration = configuration
        super.init(frame: .zero)
        workingDirectory = configuration.workingDirectory
        setAccessibilityIdentifier("duckpad.terminal.surface")
        setAccessibilityLabel(L10n.text("Terminal"))
        setAccessibilityRole(.textArea)
        setAccessibilityElement(true)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { nil }
    isolated deinit { shutdown() }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }
    override var needsCloseConfirmation: Bool {
        return launchTask != nil && !exited && !stopped
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: observedWindow)
        }
        observedWindow = window
        if let window {
            NotificationCenter.default.addObserver(self, selector: #selector(screenChanged),
                name: NSWindow.didChangeScreenNotification, object: window)
        }
        if window != nil, surface == nil, !stopped {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil, self.surface == nil, !self.stopped else { return }
                self.window?.contentView?.layoutSubtreeIfNeeded()
                guard self.bounds.width > 0, self.bounds.height > 0 else { return }
                self.start()
            }
        }
        if let surface { ghostty_surface_set_occlusion(surface, window != nil && !isHiddenOrHasHiddenAncestor) }
        scheduleGeometryUpdate()
    }
    private func start() {
        guard launchTask == nil else { return }
        host.onExit = { [weak self] _ in
            guard let self, !self.stopped, !self.exited else { return }
            self.exited = true
            self.setAccessibilityHelp(L10n.text("Terminal session ended. Press any key to close."))
            self.toolTip = L10n.text("Terminal session ended. Press any key to close.")
            let label = NSTextField(labelWithString: L10n.text("Terminal session ended. Press any key to close."))
            label.lineBreakMode = .byTruncatingTail
            label.font = .systemFont(ofSize: 11)
            label.textColor = .white
            label.drawsBackground = true
            label.backgroundColor = .darkGray
            label.translatesAutoresizingMaskIntoConstraints = false
            self.addSubview(label)
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: self.leadingAnchor, constant: 8),
                label.trailingAnchor.constraint(lessThanOrEqualTo: self.trailingAnchor, constant: -8),
                label.bottomAnchor.constraint(equalTo: self.bottomAnchor, constant: -4),
            ])
        }
        launchTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let master = try await self.host.start(directory: self.configuration.workingDirectory)
                guard !self.stopped, let app = self.runtime.app else { self.host.stop(); return }
                var config = ghostty_surface_config_new()
                config.platform_tag = GHOSTTY_PLATFORM_MACOS
                config.platform.macos.nsview = Unmanaged.passUnretained(self).toOpaque()
                config.userdata = Unmanaged.passUnretained(self).toOpaque()
                config.scale_factor = Double(self.window?.backingScaleFactor ?? 1)
                config.font_size = 12
                self.surface = "DUCKPAD_HOST_PTY_FD".withCString { key in
                    String(master.fileDescriptor).withCString { value in
                        var variable = ghostty_env_var_s(key: key, value: value)
                        return withUnsafeMutablePointer(to: &variable) {
                            config.env_vars = $0; config.env_var_count = 1
                            return ghostty_surface_new(app, &config)
                        }
                    }
                }
                guard let surface = self.surface else { self.host.stop(); self.showFailure(); return }
                self.updateSize()
                ghostty_surface_set_occlusion(surface, self.window != nil && !self.isHiddenOrHasHiddenAncestor)
                ghostty_surface_set_focus(surface, self.window?.firstResponder === self)
            } catch {
                guard !self.stopped else { return }
                self.host.stop(); self.showFailure()
            }
        }
    }
    private func showFailure() {
        stopped = true
        let label = NSTextField(wrappingLabelWithString: L10n.text("Unable to start terminal."))
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 12),
        ])
    }
    override func shutdown() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeScreenNotification, object: observedWindow)
        inspectorController?.shutdown()
        inspectorController = nil
        stopped = true
        onExit = nil
        launchTask?.cancel(); launchTask = nil
        // Ghostty joins its PTY reader during free. Stop the independent host
        // first so continuous output cannot keep that reader alive indefinitely.
        host.stop()
        if let surface { self.surface = nil; ghostty_surface_free(surface) }
    }
    override func layout() { super.layout(); scheduleGeometryUpdate() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); scheduleGeometryUpdate() }
    override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); scheduleGeometryUpdate() }
    override func viewDidHide() {
        super.viewDidHide()
        if let surface { ghostty_surface_set_occlusion(surface, false) }
    }
    override func viewDidUnhide() {
        super.viewDidUnhide()
        if let surface { ghostty_surface_set_occlusion(surface, window != nil) }
        scheduleGeometryUpdate()
    }
    @objc private func screenChanged() { scheduleGeometryUpdate() }
    private func scheduleGeometryUpdate() {
        guard !geometryUpdatePending, !stopped else { return }
        geometryUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryUpdatePending = false
            self.updateSize()
        }
    }
    private func updateSize() {
        // Reparenting a split temporarily produces zero-sized/detached views.
        // Never reflow a live terminal into a one-cell grid during that transition.
        guard let surface, window != nil, !isHiddenOrHasHiddenAncestor, bounds.width >= 16, bounds.height >= 16 else { return }
        let scale = window?.backingScaleFactor ?? 1
        // Ghostty owns a layer-hosting view. Its IOSurface must match both
        // the backing pixel size and the layer's contentsScale after a screen move.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contentsScale = scale
        CATransaction.commit()
        ghostty_surface_set_content_scale(surface, scale, scale)
        ghostty_surface_set_size(surface, UInt32(max(1, bounds.width * scale)), UInt32(max(1, bounds.height * scale)))
        if let screen = window?.screen,
           let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            ghostty_surface_set_display_id(surface, display.uint32Value)
        }
        ghostty_surface_refresh(surface)

    }
    override func becomeFirstResponder() -> Bool {
        runtime.focusedSurface = self
        onFocus?()
        if let surface { ghostty_surface_set_focus(surface, true) }
        return true
    }
    override func resignFirstResponder() -> Bool {
        if let surface { ghostty_surface_set_focus(surface, false) }
        return true
    }
    private func mods(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var value: UInt32 = 0
        for (flag, bit) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.control, GHOSTTY_MODS_CTRL),
                            (.option, GHOSTTY_MODS_ALT), (.command, GHOSTTY_MODS_SUPER), (.capsLock, GHOSTTY_MODS_CAPS)] {
            if flags.contains(flag) { value |= bit.rawValue }
        }
        return ghostty_input_mods_e(rawValue: value)
    }
    override func keyDown(with event: NSEvent) {
        if exited { onExit?(); return }
        guard surface != nil else { return }
        if !hasMarkedText(), isBinding(event) {
            sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: event.characters)
            return
        }
        let hadMarked = hasMarkedText()
        keyText = []
        // Keep the original event identity: Korean input methods depend on it.
        interpretKeyEvents([event])
        syncPreedit()
        let texts = keyText ?? []
        keyText = nil
        let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        if texts.isEmpty {
            sendKey(event, action: action, text: event.characters, composing: hadMarked || hasMarkedText())
        } else {
            for text in texts { sendKey(event, action: action, text: text) }
        }
    }
    override func keyUp(with event: NSEvent) { sendKey(event, action: GHOSTTY_ACTION_RELEASE) }
    private func sendKey(_ event: NSEvent, action: ghostty_input_action_e, text: String? = nil, composing: Bool = false) {
        guard let surface else { return }
        var key = ghostty_input_key_s()
        key.action = action
        key.keycode = UInt32(event.keyCode)
        key.mods = mods(event.modifierFlags)
        key.consumed_mods = mods(event.modifierFlags.intersection([.shift, .option]))
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        key.composing = composing
        if let text, let first = text.unicodeScalars.first, first.value >= 0x20, first.value != 0x7f, !(0xF700...0xF8FF).contains(first.value) {
            text.withCString { key.text = $0; _ = ghostty_surface_key(surface, key) }
        } else { _ = ghostty_surface_key(surface, key) }
    }
    private func isBinding(_ event: NSEvent) -> Bool {
        guard let surface else { return false }
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.keycode = UInt32(event.keyCode)
        key.mods = mods(event.modifierFlags)
        key.unshifted_codepoint = event.characters(byApplyingModifiers: [])?.unicodeScalars.first?.value ?? 0
        key.composing = hasMarkedText()
        key.consumed_mods = mods(event.modifierFlags.intersection([.shift, .option, .capsLock]))
        return (event.characters ?? "").withCString {
            key.text = $0
            return ghostty_surface_key_is_binding(surface, key, nil)
        }
    }

    override func handleTerminalKeyEquivalent(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, !hasMarkedText(), isBinding(event) else { return false }
        if let editor = window?.firstResponder as? NSTextView, editor.isFieldEditor,
           editor.delegate === searchBar?.field {
            // Keep text editing shortcuts in the search field. Only search navigation
            // and dismissal are forwarded while its field editor owns focus.
            let flags = event.modifierFlags.intersection([.command, .shift, .control, .option])
            let key = event.charactersIgnoringModifiers?.lowercased()
            guard event.keyCode == 53 || (flags == .command && ["f", "g", "e"].contains(key ?? ""))
                || (flags == [.command, .shift] && ["f", "g"].contains(key ?? "")) else { return false }
        }
        sendKey(event, action: event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS, text: event.characters)
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else { return false }
        return handleTerminalKeyEquivalent(event)
    }

    override func performBinding(_ binding: String) -> Bool {
        guard let surface else { return false }
        return binding.withCString { ghostty_surface_binding_action(surface, $0, UInt(binding.utf8.count)) }
    }

    override func canPerform(_ command: EditorCommand) -> Bool {
        guard let surface else { return false }
        switch command {
        case .copy: return ghostty_surface_has_selection(surface)
        case .paste: return NSPasteboard.general.string(forType: .string) != nil
        case .selectAll: return true
        default: return false
        }
    }
    override func perform(_ command: EditorCommand) {
        switch command {
        case .copy: copy(nil)
        case .paste: paste(nil)
        case .selectAll:
            if let surface { _ = "select_all".withCString { ghostty_surface_binding_action(surface, $0, 10) } }
        default: break
        }
    }
    @objc func copy(_ sender: Any?) {
        guard let surface else { return }
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return }
        defer { ghostty_surface_free_text(surface, &text) }
        guard let pointer = text.text else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(cString: pointer), forType: .string)
    }
    @objc func paste(_ sender: Any?) {
        _ = performBinding("paste_from_clipboard")
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area); tracking = area
    }
    override func mouseMoved(with event: NSEvent) {
        guard let surface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, point.y, mods(event.modifierFlags))
    }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); mouseMoved(with: event)
        if let surface { _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods(event.modifierFlags)) }
    }
    override func mouseUp(with event: NSEvent) {
        mouseMoved(with: event)
        if let surface { _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods(event.modifierFlags)) }
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func scrollWheel(with event: NSEvent) {
        if let surface { ghostty_surface_mouse_scroll(surface, event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0) }
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .iBeam) }

    func hasMarkedText() -> Bool { marked.length > 0 }
    func markedRange() -> NSRange { hasMarkedText() ? NSRange(location: 0, length: marked.length) : NSRange(location: NSNotFound, length: 0) }
    func selectedRange() -> NSRange { selection }
    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        marked = (string as? NSAttributedString) ?? NSAttributedString(string: string as? String ?? "")
        selection = selectedRange
        syncPreedit()
    }
    func unmarkText() { marked = NSAttributedString(string: ""); syncPreedit() }
    private func syncPreedit() {
        guard let surface else { return }
        if marked.length == 0 { ghostty_surface_preedit(surface, nil, 0) }
        else { marked.string.withCString { ghostty_surface_preedit(surface, $0, UInt(marked.string.utf8.count)) } }
    }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
    func characterIndex(for point: NSPoint) -> Int { NSNotFound }
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface, let window else { return .zero }
        var x = 0.0, y = 0.0, width = 0.0, height = 0.0
        ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        return window.convertToScreen(convert(NSRect(x: x, y: y, width: width, height: height), to: nil))
    }
    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = (string as? NSAttributedString)?.string ?? string as? String ?? ""
        unmarkText()
        if keyText != nil { keyText?.append(text) }
        else if let surface { text.withCString { ghostty_surface_text(surface, $0, UInt(text.utf8.count)) } }
    }
    override func doCommand(by selector: Selector) { /* Physical keys are encoded by Ghostty. */ }
}
