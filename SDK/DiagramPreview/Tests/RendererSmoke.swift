import AppKit

/// Isolated renderer process; no host documents or installed plugin state.
@main @MainActor final class RendererSmoke: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared, delegate = RendererSmoke()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let web = DiagramWebRenderer(deadline: .seconds(10))
                let svg = """
                <svg xmlns="http://www.w3.org/2000/svg" width="100" height="80" viewBox="0 0 100 80" onload="alert('blocked')">
                <script>alert('blocked')</script><image href="https://example.com/never.svg"/>
                <rect x="0" y="0" width="100" height="80" fill="#ff0000"/></svg>
                """
                let image = try await web.render(kind: "svg", source: svg, dark: false)
                let bitmap = NSBitmapImageRep(data: image.png)!
                let center = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)!.usingColorSpace(.deviceRGB)!
                precondition(center.redComponent > 0.9 && center.blueComponent < 0.1, "Snapshot must contain the rendered SVG")
                let clean = String(decoding: image.svg, as: UTF8.self)
                precondition(!clean.contains("<script") && !clean.contains("onload") && !clean.contains("example.com"))
                print("PASS: SVG pixels, script/event/external-link removal and PNG export")
                for (width, height) in [("0.001", "1000000"), ("1000000", "0.001")] {
                    let extreme = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"\(width)\" height=\"\(height)\" viewBox=\"0 0 \(width) \(height)\"/>"
                    do { _ = try await web.render(kind: "svg", source: extreme, dark: false); fatalError("Extreme aspect ratio accepted") }
                    catch is DiagramFailure { }
                }
                print("PASS: extreme SVG aspect ratios rejected before snapshot allocation")
                let renderer = MermaidRenderer()
                for (source, dark) in [("flowchart LR\n  Client[고객] --> Server[서버]", false),
                                       ("sequenceDiagram\n  Alice->>Bob: 안녕하세요\n  Bob-->>Alice: Ready", true),
                                       ("classDiagram\n  class Duck {\n    +paddle()\n  }", false)] {
                    let result = try await renderer.render(source, dark: dark, runtimePath: "", install: false)
                    precondition(result.width > 10 && result.height > 10 && !result.png.isEmpty)
                    let rep = NSBitmapImageRep(data: result.png)!
                    var colors = Set<String>()
                    for y in stride(from: 0, to: rep.pixelsHigh, by: max(1, rep.pixelsHigh / 30)) {
                        for x in stride(from: 0, to: rep.pixelsWide, by: max(1, rep.pixelsWide / 30)) {
                            if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) {
                                colors.insert(String(format: "%.2f/%.2f/%.2f", color.redComponent, color.greenComponent, color.blueComponent))
                            }
                        }
                    }
                    precondition(colors.count > 1, "Mermaid PNG must contain the diagram, not an empty background")
                    precondition(String(decoding: result.svg, as: UTF8.self).contains("<svg"))
                    print("PASS: Mermaid", source.components(separatedBy: .newlines)[0], dark ? "dark" : "light", result.width, result.height)
                }
                do { _ = try await renderer.render("not a diagram {{{", dark: false, runtimePath: "", install: false); fatalError("invalid Mermaid accepted") }
                catch is DiagramFailure { print("PASS: invalid Mermaid reports failure") }
                let cancelled = Task { try await web.render(kind: "svg", source: svg, dark: false) }
                try await Task.sleep(for: .milliseconds(1))
                web.cancel()
                do { _ = try await cancelled.value; fatalError("cancelled render completed") }
                catch is CancellationError { print("PASS: renderer cancellation") }
                let after = try await web.render(kind: "svg", source: svg, dark: true)
                precondition(!after.png.isEmpty)
                web.cancel(); renderer.cancel()
                print("PASS: fresh render after cancellation; no stale response")
                fflush(stdout); NSApp.terminate(nil)
            } catch { print("FAIL: renderer smoke", error); fflush(stdout); exit(1) }
        }
    }
}
