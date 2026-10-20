import AppKit

/// Two complete, unmodified Shift taps. Typing and other gestures disarm it.
struct DoubleShiftGesture {
    private var pressedAt: TimeInterval?
    private var releasedAt: TimeInterval?
    private var shiftIsDown = false

    mutating func reset() {
        pressedAt = nil; releasedAt = nil; shiftIsDown = false
    }

    mutating func handle(_ event: NSEvent) -> Bool {
        guard event.type == .flagsChanged, [56, 60].contains(event.keyCode) else {
            reset(); return false
        }
        let flags = event.modifierFlags.intersection([.shift, .command, .control, .option, .capsLock, .function])
        let down = flags.contains(.shift)
        guard flags.subtracting(.shift).isEmpty, down != shiftIsDown else {
            reset(); return false
        }
        shiftIsDown = down
        if down {
            pressedAt = event.timestamp
            return false
        }
        guard let pressedAt, event.timestamp >= pressedAt, event.timestamp - pressedAt <= 0.25 else {
            reset(); return false
        }
        self.pressedAt = nil
        if let releasedAt, pressedAt >= releasedAt, event.timestamp - releasedAt <= 0.4 {
            reset(); return true
        }
        releasedAt = event.timestamp
        return false
    }
}
