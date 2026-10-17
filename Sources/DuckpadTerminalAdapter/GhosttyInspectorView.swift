import AppKit
import MetalKit
import GhosttyKit

/// Inspector rendering/input follows the pinned upstream InspectorView (see PROVENANCE.md).
@MainActor
final class GhosttyInspectorView: MTKView {
    private var inspector: ghostty_inspector_t?
    private let queue: MTLCommandQueue

    init?(inspector: ghostty_inspector_t) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        self.queue = queue
        self.inspector = inspector
        super.init(frame: .zero, device: device)
        guard ghostty_inspector_metal_init(inspector, Unmanaged.passRetained(device).toOpaque()) else { return nil }
        preferredFramesPerSecond = 30
        clearColor = MTLClearColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
    }
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { if let inspector { ghostty_inspector_set_focus(inspector, true) }; return true }
    override func resignFirstResponder() -> Bool { if let inspector { ghostty_inspector_set_focus(inspector, false) }; return true }
    func shutdown() {
        isPaused = true
        if let inspector { _ = ghostty_inspector_metal_shutdown(inspector) }
        inspector = nil
    }
    override func draw(_ dirtyRect: NSRect) {
        guard let inspector, window?.isVisible == true, let buffer = queue.makeCommandBuffer(),
              let descriptor = currentRenderPassDescriptor, let drawable = currentDrawable else { return }
        let scale = window?.backingScaleFactor ?? 1
        ghostty_inspector_set_content_scale(inspector, scale, scale)
        ghostty_inspector_set_size(inspector, UInt32(max(1, drawableSize.width)), UInt32(max(1, drawableSize.height)))
        ghostty_inspector_metal_render(inspector, Unmanaged.passRetained(buffer).toOpaque(), Unmanaged.passRetained(descriptor).toOpaque())
        buffer.present(drawable); buffer.commit()
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved], owner: self))
    }
    override func mouseMoved(with event: NSEvent) {
        guard let inspector else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_inspector_mouse_pos(inspector, point.x, bounds.height - point.y)
    }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self); mouseMoved(with: event)
        if let inspector { ghostty_inspector_mouse_button(inspector, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, Self.mods(event)) }
    }
    override func mouseUp(with event: NSEvent) {
        if let inspector { ghostty_inspector_mouse_button(inspector, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, Self.mods(event)) }
    }
    override func rightMouseDown(with event: NSEvent) {
        mouseMoved(with: event)
        if let inspector { ghostty_inspector_mouse_button(inspector, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, Self.mods(event)) }
    }
    override func rightMouseUp(with event: NSEvent) {
        if let inspector { ghostty_inspector_mouse_button(inspector, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, Self.mods(event)) }
    }
    override func scrollWheel(with event: NSEvent) {
        if let inspector { ghostty_inspector_mouse_scroll(inspector, event.scrollingDeltaX, event.scrollingDeltaY, event.hasPreciseScrollingDeltas ? 1 : 0) }
    }
    override func keyDown(with event: NSEvent) {
        guard let inspector else { return }
        ghostty_inspector_key(inspector, event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS,
                              GhosttyInspectorKeys.key(event.keyCode), Self.mods(event))
        if event.modifierFlags.intersection([.command, .control]).isEmpty,
           let text = event.characters, text.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value < 0xF700 }) {
            text.withCString { ghostty_inspector_text(inspector, $0) }
        }
    }
    override func keyUp(with event: NSEvent) {
        if let inspector { ghostty_inspector_key(inspector, GHOSTTY_ACTION_RELEASE, GhosttyInspectorKeys.key(event.keyCode), Self.mods(event)) }
    }
    private static func mods(_ event: NSEvent) -> ghostty_input_mods_e {
        var bits: UInt32 = 0
        for (flag, value) in [(NSEvent.ModifierFlags.shift, GHOSTTY_MODS_SHIFT), (.command, GHOSTTY_MODS_SUPER), (.control, GHOSTTY_MODS_CTRL), (.option, GHOSTTY_MODS_ALT)] {
            if event.modifierFlags.contains(flag) { bits |= value.rawValue }
        }
        return ghostty_input_mods_e(rawValue: bits)
    }
}
