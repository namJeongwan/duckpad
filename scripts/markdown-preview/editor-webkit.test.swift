import AppKit
import WebKit

/// Isolated real WebKit input: never loads host settings, recovery or user files.
@main @MainActor final class MarkdownListWebKitSmoke: NSObject, NSApplicationDelegate, WKScriptMessageHandlerWithReply {
    private var web: WKWebView!
    private var window: NSWindow!
    private var edits = 0
    static func main() {
        let app = NSApplication.shared, delegate = MarkdownListWebKitSmoke()
        app.delegate = delegate; app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
    func applicationDidFinishLaunching(_ notification: Notification) {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "duckpadEditor")
        web = WKWebView(frame: .zero, configuration: configuration)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 850),
                          styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.title = "Duckpad Markdown input regression"
        window.contentView = web; NSApp.activate(ignoringOtherApps: true); window.makeKeyAndOrderFront(nil)
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).deletingLastPathComponent().deletingLastPathComponent()
        web.loadFileURL(root.appendingPathComponent(".build/markdown-editor-browser/index.html"), allowingReadAccessTo: root)
        Task { @MainActor in
            do { try await Task.sleep(for: .seconds(60)); fputs("FAIL: WebKit regression timeout\n", stderr); exit(1) }
            catch {}
        }
        Task { @MainActor in
            do {
                try await wait("!!window.testView&&!!window.DuckpadEditor")
                for width in [520, 1000] {
                    window.setContentSize(NSSize(width: width, height: 850))
                    for index in 0..<6 {
                        _ = try await js("DuckpadEditor.load({text:testCases[\(index)].text,generation:1,editable:true,live:true,fontSize:16,zoom:0,theme:'light',colors:{bg:'#fafafa',fg:'#202020',muted:'#656b78',border:'#dfdfe0',code:'#ebebec'},anchor:0,caret:0});true")
                        try await wait("document.querySelectorAll('.md-list').length===5&&[...document.querySelectorAll('img.md-image')].every(i=>i.complete&&i.naturalWidth>0)&&!document.querySelector('.md-diagram:not([data-state=ready])')")
                        _ = try await js("document.querySelector('.md-list').scrollIntoView({block:'center'});testView().requestMeasure();true")
                        try await Task.sleep(for: .milliseconds(100))
                        let first = try await js("testCases[\(index)].text.slice(0,testCases[\(index)].text.indexOf('1. 첫')).split('\\n').length") as! Int
                        _ = try await js("(()=>{const v=testView();v.dispatch({selection:{anchor:v.state.doc.line(\(first)).from+3},scrollIntoView:true});v.focus();return true;})()")
                        try await Task.sleep(for: .milliseconds(150))
                        let aligned = try await js("(()=>{const v=testView();return [...document.querySelectorAll('.md-list')].every((e,i)=>Math.abs(e.getBoundingClientRect().top-v.documentTop-v.lineBlockAt(v.state.doc.line(\(first)+i).from).top)<1);})()") as! Bool
                        try expect(aligned, "WebKit height map must match rendered rows")
                        for row in 1..<5 { try await key(down: true); try await expectLine(first + row) }
                        for row in (0..<4).reversed() { try await key(down: false); try await expectLine(first + row) }
                        for row in 0..<5 {
                            let point = try await js("(()=>{const e=document.querySelectorAll('.md-list')[\(row)];e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return {x:r.left+100,y:r.top+r.height/2};})()") as! [String: Double]
                            let local = NSPoint(x: point["x"]!, y: web.isFlipped ? point["y"]! : web.bounds.height - point["y"]!)
                            let location = web.convert(local, to: nil)
                            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                                window.sendEvent(NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                    windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
                            }
                            try await Task.sleep(for: .milliseconds(80)); try await expectLine(first + row)
                        }
                        let unchanged = try await js("DuckpadEditor.diagnostics().raw===testCases[\(index)].text") as! Bool
                        try expect(unchanged, "Navigation changes source")
                        print("PASS: WebKit native clicks/Up/Down, block \(index), width \(width), source preserved")
                    }
                }
                try expect(edits == 0, "Navigation must not create document edits or Undo entries")
                print("PASS: 12 WebKit native input cases; no skipped rows or edits")
                fflush(stdout); web.configuration.userContentController.removeScriptMessageHandler(forName: "duckpadEditor", contentWorld: .page)
                window.close(); NSApp.terminate(nil)
            } catch { print("FAIL: WebKit input regression", error); fflush(stdout); exit(1) }
        }
    }
    private func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain: "MarkdownWebKitSmoke", code: 2, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private func js(_ source: String) async throws -> Any { try await web.evaluateJavaScript(source) ?? NSNull() }
    private func wait(_ condition: String) async throws {
        for _ in 0..<200 {
            if (try? await js(condition)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(30))
        }
        throw NSError(domain: "MarkdownWebKitSmoke", code: 1, userInfo: [NSLocalizedDescriptionKey: "Condition not ready: " + condition])
    }
    private func key(down: Bool) async throws {
        let character = String(UnicodeScalar(down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey)!)
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            NSApp.sendEvent(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.function, .numericPad], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: down ? 125 : 126)!)
        }
        try await Task.sleep(for: .milliseconds(50))
    }
    private func expectLine(_ expected: Int) async throws {
        let actual = try await js("testView().state.doc.lineAt(testView().state.selection.main.head).number") as! Int
        try expect(actual == expected, "Expected line \(expected), got \(actual)")
    }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        if (message.body as? [String: Any])?["type"] as? String == "edit" { edits += 1 }
        replyHandler(["accepted": true], nil)
    }
}
