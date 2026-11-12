import AppKit

/// Runs in a disposable sandboxed app using the candidate's unchanged signed helper.
@main @MainActor final class PackagedRendererSmoke: NSObject, NSApplicationDelegate {
    static func main() {
        let app = NSApplication.shared, delegate = PackagedRendererSmoke()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            do {
                let path = CommandLine.arguments[1]
                let d2 = D2Connection(), web = DiagramWebRenderer()
                let svg = try await d2.render(.init(source: "client -> server: 안녕하세요", executablePath: path, dark: true))
                let diagram = try await web.render(kind: "svg", source: String(decoding: svg, as: UTF8.self), dark: true)
                precondition(String(decoding: diagram.svg, as: UTF8.self).contains("안녕하세요") && !diagram.png.isEmpty)
                print("PASS: sandboxed native plugin renderer -> authenticated candidate XPC helper -> sandboxed D2 -> WebKit PNG/SVG")
                do { _ = try await d2.render(.init(source: "a: {", executablePath: path)); fatalError("Invalid D2 accepted") }
                catch let failure as DiagramFailure { precondition(failure.code == "renderFailed") }
                print("PASS: actual helper error reply reaches plugin")
                let mermaid = MermaidRenderer()
                let result = try await mermaid.render("flowchart LR\n  Client[고객] --> Server[서버]", dark: true, runtimePath: "", install: false)
                precondition(String(decoding: result.svg, as: UTF8.self).contains("고객") && !result.png.isEmpty)
                print("PASS: sandboxed embedded Mermaid -> WebKit PNG/SVG")
                d2.close(); web.cancel(); mermaid.cancel(); fflush(stdout); NSApp.terminate(nil)
            } catch { print("FAIL: packaged diagram render", error); fflush(stdout); exit(1) }
        }
    }
}
