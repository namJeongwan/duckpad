import AppKit
@testable import DuckpadPresentation
import Testing

@MainActor
struct EditorWindowTests {
    @Test func onlyNativeFrameBandReceivesResizeCursor() {
        guard #available(macOS 15.0, *) else { return }
        let frame = NSRect(x: 100, y: 100, width: 600, height: 400)
        let cases: [(NSPoint, NSCursor.FrameResizePosition)] = [
            (.init(x: 102, y: 300), .left), (.init(x: 698, y: 300), .right),
            (.init(x: 400, y: 498), .top), (.init(x: 400, y: 102), .bottom),
            (.init(x: 102, y: 498), .topLeft), (.init(x: 698, y: 498), .topRight),
            (.init(x: 102, y: 102), .bottomLeft), (.init(x: 698, y: 102), .bottomRight),
            (.init(x: 98, y: 300), .left), (.init(x: 400, y: 98), .bottom),
        ]
        for (point, expected) in cases {
            #expect(EditorWindow.resizePosition(at: point, frame: frame) == expected)
        }
        for point in [NSPoint(x: 400, y: 300), .init(x: 110, y: 480),
                      .init(x: 400, y: 490), .init(x: 96, y: 300), .init(x: 705, y: 505)] {
            #expect(EditorWindow.resizePosition(at: point, frame: frame) == nil)
        }
    }
}
