import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadScintillaBridge
import DuckpadInfrastructure
@testable import DuckpadEditorAdapter
import Testing
import WebKit

@Suite(.serialized) @MainActor
struct CodeMirrorEditorTests {
    private func fixture(_ source: String, bufferID: BufferID = BufferID(),
                         accept: ((EditorIncrementalEdit) -> EditorEditOutcome)? = nil) async throws -> (NSWindow, ScintillaEditorAdapter, BufferID, CodeMirrorEditorView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: .init(x: 0, y: 0, width: 960, height: 800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let editor = ScintillaEditorAdapter()
        editor.onEdit = accept ?? { .accepted(newRevision: $0.expectedRevision + 1) }
        window.contentView = editor.view
        editor.view.frame = window.contentView!.bounds
        let buffer = bufferID
        editor.display(.init(bufferID: buffer, revision: 0))
        editor.install(.init(bufferID: buffer, revision: 0, text: source))
        editor.activeScintillaView?.setPrimarySelectionUTF8Range(.init(location: source.utf8.count, length: 0))
        #expect(editor.applyLanguage(.init(languageID: .init(rawValue: "markdown"), lexerName: "markdown",
                                           indentation: .init(), folding: false, braceMatching: false)))
        let web = try #require(editor.activeCodeMirrorEditor)
        window.orderFront(nil)
        for _ in 0..<400 {
            if (try? await web.webView.evaluateJavaScript("!!window.DuckpadEditor && !!document.querySelector('.cm-editor')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await editor.synchronizePendingInput())
        #expect((try await diagnostics(web))["raw"] as? String == source)
        return (window, editor, buffer, web)
    }

    private func diagnostics(_ view: CodeMirrorEditorView) async throws -> [String: Any] {
        try #require(try await view.webView.evaluateJavaScript("window.DuckpadEditor.diagnostics()") as? [String: Any])
    }

    private func dispatch(_ view: CodeMirrorEditorView, _ transaction: [String: Any]) async throws {
        _ = try await view.webView.callAsyncJavaScript("window.DuckpadEditor.dispatch(transaction)",
            arguments: ["transaction": transaction], in: nil, contentWorld: .page)
        #expect(await view.flush())
    }

    private func waitFor(_ expression: String, in web: CodeMirrorEditorView) async throws {
        for _ in 0..<600 {
            if (try? await web.webView.evaluateJavaScript(expression)) as? Bool == true { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        Issue.record("Timed out waiting for WebKit: \(expression); \(web.lastScriptError ?? "no script error")")
    }

    private func capture(_ web: CodeMirrorEditorView, name: String) async throws {
        guard let directory = ProcessInfo.processInfo.environment["DUCKPAD_MARKDOWN_LIVE_SNAPSHOTS"] else { return }
        let image = try await web.webView.takeSnapshot(configuration: nil)
        let data = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
        let root = URL(fileURLWithPath: directory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(name + ".png"))
    }

    private func pressArrow(_ key: String, in web: CodeMirrorEditorView, shift: Bool = false, composing: Bool = false) async throws -> Bool {
        let prevented = try await web.webView.callAsyncJavaScript("const event=new KeyboardEvent('keydown',{key,code:key,keyCode:{ArrowLeft:37,ArrowUp:38,ArrowRight:39,ArrowDown:40}[key],shiftKey:shift,isComposing:composing,bubbles:true,cancelable:true});document.activeElement.dispatchEvent(event);return event.defaultPrevented;",
            arguments: ["key": key, "shift": shift, "composing": composing], in: nil, contentWorld: .page) as? Bool
        #expect(await web.flush())
        return prevented ?? false
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["DUCKPAD_MARKDOWN_PERF"] == "1"))
    func markdownTypingAndDragPerformance() async throws {
        let chunk = "## Section 한글\n\nParagraph **bold** and `code` with [link](../source/file.rs). 한글 문서의 편집 성능을 측정합니다.\n\n- [ ] Task item\n- More text\n\n| A | B |\n| --- | --- |\n| one | two |\n\n```swift\nlet value = 42\n```\n\n"
        for repetitions in [300,1200] {
            let source = String(repeating: chunk, count: repetitions) + "\nTyping here: "
            let (window, editor, buffer, web) = try await fixture(source)
            defer { editor.invalidate(); window.close() }
            _ = try await web.webView.evaluateJavaScript("window.DuckpadEditor.focus()")
            try await Task.sleep(for: .milliseconds(500))
            let result = try #require(try await web.webView.callAsyncJavaScript("""
                const api=window.DuckpadEditor, samples={typing:[],drag:[]},frames={typing:[],drag:[]};
                const frame=()=>new Promise(resolve=>setTimeout(resolve,0));
                let end=api.diagnostics().text.length;
                for(let index=0;index<24;index++) {
                    const start=performance.now();api.dispatch({changes:{from:end,insert:'a'},selection:{anchor:++end}});
                    samples.typing.push(performance.now()-start);await api.flush();await frame();frames.typing.push(performance.now()-start);
                }
                const line=document.querySelector('.cm-content .cm-line');
                line.dispatchEvent(new MouseEvent('mousedown',{button:0,buttons:1,bubbles:true,cancelable:true}));
                for(let index=0;index<24;index++) {
                    const start=performance.now();api.dispatch({selection:{anchor:end-64,head:end-24+index}});
                    samples.drag.push(performance.now()-start);await api.flush();await frame();frames.drag.push(performance.now()-start);
                }
                window.dispatchEvent(new MouseEvent('mouseup',{button:0,bubbles:true}));
                const summary=values=>{const sorted=[...values].sort((a,b)=>a-b);return {mean:values.reduce((a,b)=>a+b,0)/values.length,p95:sorted[Math.ceil(values.length*.95)-1],max:sorted.at(-1)}};
                return {dispatch:{typing:summary(samples.typing),drag:summary(samples.drag)},bridge:{typing:summary(frames.typing),drag:summary(frames.drag)}};
                """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any])
            #expect(await editor.synchronizePendingInput())
            #expect(editor.snapshot(for: buffer)?.text == source + String(repeating: "a", count: 24))
            let record: [String: Any] = ["bytes": source.utf8.count, "lines": source.filter { $0 == "\n" }.count + 1, "result": result]
            let data = try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print("MARKDOWN_PERF " + String(decoding: data, as: UTF8.self))
        }
    }

    @Test func mathRendersInlineAndAsEditableDisplayBlocksWithoutChangingBytes() async throws {
        let source = "# Math\r\n\r\nInline $x_1+x_2$.\r\n\r\n$$\r\n\\frac{a}{b}\r\n$$\r\n\r\n`$code$` and \\$escaped.\r\n\r\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        try await waitFor("document.querySelectorAll('.md-math .katex').length===2", in: web)
        try await capture(web, name: "live-math")
        #expect(try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-math-inline').length===1 && document.querySelectorAll('.md-math-block').length===1") as? Bool == true)
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-math-block').dispatchEvent(new MouseEvent('mousedown',{button:0,bubbles:true,cancelable:true}))")
        try await waitFor("document.querySelector('.cm-content').textContent.includes('\\\\frac') && !!document.querySelector('.md-math-block .katex')", in: web)
        let position = (source.replacingOccurrences(of: "\r\n", with: "\n") as NSString).range(of: "{a}").location + 1
        try await dispatch(web, ["changes": ["from": position, "to": position+1, "insert": "c"]])
        #expect(editor.snapshot(for: buffer)?.text == source.replacingOccurrences(of: "{a}", with: "{c}"))
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
        _ = try await web.webView.callAsyncJavaScript("await document.fonts.ready;return true", arguments: [:], in: nil, contentWorld: .page)
        #expect(try await web.webView.evaluateJavaScript("Array.from(document.fonts).some(f=>f.family==='KaTeX_Main'&&f.status==='loaded')") as? Bool == true)
        editor.setMarkdownLiveEditingEnabled(false)
        #expect(await editor.synchronizePendingInput())
        #expect(try await web.webView.evaluateJavaScript("!document.querySelector('.md-math') && document.querySelector('.cm-content').textContent.includes('$x_1+x_2$')") as? Bool == true)
    }

    @Test func changingLanguageFlushesActiveTableCompositionBeforeDetachingMarkdown() async throws {
        var session = ScratchSession()
        let tab = session.addUntitled()
        try session.changeFileLocation(tabID: tab, binding: nil, title: "notes.md")
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore(session: session))
        _ = await workspace.start()
        let id = try #require(workspace.fileContext(tabID: tab)).buffer.bufferID
        let source = "| A | B |\r\n| --- | --- |\r\n| one | two |\r\n\r\nEnd"
        let (window, editor, _, web) = try await fixture(source, bufferID: id, accept: { workspace.acceptEditorEdit($0) })
        defer { editor.invalidate(); window.close() }
        let binding = EditorBindingUseCase(workspace: workspace, editor: editor)
        workspace.onChange = { binding.render($0) }
        let language = LanguageWorkspaceUseCase(registry: try LanguageManifestLoader().loadBundled(), workspace: workspace, editor: editor)
        _ = language.refreshActive()
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-editable-table').tableController.activate(1,0);const input=document.activeElement;input.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));input.value='입력 중 🦆';input.dispatchEvent(new InputEvent('input',{bubbles:true,isComposing:true}));")
        try await waitFor("window.DuckpadEditor.diagnostics().composing", in: web)
        #expect(editor.toggleLineComment(prefix: "//") == .rejected(currentRevision: 0))
        guard case .applied = await language.setOverride(.manual(.plainText)) else { Issue.record("Language switch failed"); return }
        #expect(editor.activeCodeMirrorEditor == nil)
        #expect(editor.snapshot(for: id)?.text == source.replacingOccurrences(of: "one", with: "입력 중 🦆"))
        editor.perform(.undo)
        #expect(editor.snapshot(for: id)?.text == source)
    }

    @Test func arrowKeysEnterTableMoveAcrossCellsAndReturnToDocumentWithoutEditing() async throws {
        let source = "Before\n\n| A | B |\n| --- | --- |\n| one | two |\n| 한글 🦆 |  |\n\nAfter"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let from = (source as NSString).range(of: "| A").location
        _ = try await web.webView.callAsyncJavaScript("window.DuckpadEditor.dispatch({selection:{anchor:position}});window.DuckpadEditor.focus()", arguments: ["position": from - 1], in: nil, contentWorld: .page)
        _ = try await pressArrow("ArrowDown", in: web)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.classList.contains('md-table-cell-input') && document.activeElement.dataset.row==='0' && document.activeElement.dataset.column==='0'") as? Bool == true)
        _ = try await pressArrow("ArrowDown", in: web)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.value") as? String == "one")
        _ = try await web.webView.evaluateJavaScript("document.activeElement.setSelectionRange(3,3)")
        _ = try await pressArrow("ArrowRight", in: web)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.value==='two' && document.activeElement.selectionStart===0") as? Bool == true)
        _ = try await pressArrow("ArrowDown", in: web)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.dataset.row==='2' && document.activeElement.dataset.column==='1'") as? Bool == true)
        _ = try await pressArrow("ArrowDown", in: web)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.classList.contains('cm-content')") as? Bool == true)
        _ = try await pressArrow("ArrowUp", in: web)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.dataset.row==='2' && document.activeElement.dataset.column==='1'") as? Bool == true)
        _ = try await pressArrow("ArrowLeft", in: web)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.value==='한글 🦆' && document.activeElement.selectionStart===5") as? Bool == true)
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect(editor.activeScintillaView?.canUndo == false)
    }

    @Test func tableArrowsKeepWrappedTextSelectionAndCompositionInsideCell() async throws {
        let source = "Before\n\n| A | B |\n| --- | --- |\n| " + String(repeating: "한글 🦆 wrapped text ", count: 30) + " | two |\n\nAfter"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-editable-table').tableController.activate(1,0);document.activeElement.setSelectionRange(0,0)")
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await pressArrow("ArrowDown", in: web) == false)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.dataset.row") as? String == "1")
        _ = try await web.webView.evaluateJavaScript("document.activeElement.setSelectionRange(1,1)")
        #expect(try await pressArrow("ArrowRight", in: web) == false)
        _ = try await web.webView.evaluateJavaScript("document.activeElement.setSelectionRange(0,0)")
        #expect(try await pressArrow("ArrowUp", in: web, composing: true) == false)
        #expect(try await pressArrow("ArrowUp", in: web, shift: true) == false)
        #expect(try await pressArrow("ArrowUp", in: web))
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.dataset.row") as? String == "0")
        #expect(try await pressArrow("ArrowUp", in: web))
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.classList.contains('cm-content')") as? Bool == true)
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect(editor.activeScintillaView?.canUndo == false)
    }

    @Test func draggingLinksKeepsRenderedGeometryUntilMouseRelease() async throws {
        let source = "근거: [수집 매크로](../fyro-server/src/trace/data.rs), [부착과 종료](../fyro-server/src/pipelines/otel/tracer.rs), [타입별 기록](../fyro-server/src/pipelines/otel/record_span_impls.rs).\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let result = try await web.webView.callAsyncJavaScript("""
            const link=document.querySelector('.md-link'),rect=link.getBoundingClientRect();
            const bounds=()=>JSON.stringify(Array.from(document.querySelectorAll('.md-link')).map(e=>{const r=e.getBoundingClientRect();return [r.x,r.y,r.width,r.height]}));
            const initial=bounds();
            link.dispatchEvent(new MouseEvent('mousedown',{button:0,buttons:1,bubbles:true,cancelable:true,clientX:rect.x+1,clientY:rect.y+rect.height/2}));
            window.DuckpadEditor.dispatch({selection:{anchor:0,head:source.length-5}});
            const during=document.querySelector('.cm-content').textContent;
            const stable=initial===bounds();
            window.dispatchEvent(new MouseEvent('mouseup',{button:0,bubbles:true}));
            return {during,stable};
            """, arguments: ["source": source], in: nil, contentWorld: .page) as? [String: Any]
        #expect(result?["stable"] as? Bool == true)
        #expect((result?["during"] as? String)?.contains("../fyro-server") == false)
        try await waitFor("document.querySelector('.cm-content').textContent.includes('../fyro-server')", in: web)
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect(editor.activeScintillaView?.canUndo == false)
    }

    @Test func cachedWidgetsKeepCorrectPositionsAfterEditsInEarlierBlocks() async throws {
        let source = "Start\n\nOther paragraph\n\n- [ ] task\n\nAnother paragraph\n\n| A | B |\n| --- | --- |\n| one | two |\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let prefix = "한글 🦆 prefix\n\n"
        try await dispatch(web, ["changes": ["from": 0, "insert": prefix]])
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-task').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}))")
        #expect(await editor.synchronizePendingInput())
        let checked = (prefix + source).replacingOccurrences(of: "[ ]", with: "[x]")
        #expect(editor.snapshot(for: buffer)?.text == checked)
        _ = try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table-cell-preview')[2].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));const input=document.activeElement;input.value='새 값';input.dispatchEvent(new Event('input',{bubbles:true}));")
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == checked.replacingOccurrences(of: "one", with: "새 값"))
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == checked)
    }

    @Test func tableContextMenuPreservesSelectionAndUsesClickPosition() async throws {
        let source = "| A | B |\n| --- | --- |\n| 한글 text | two |\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let saved = NSPasteboard.general.string(forType: .string)
        defer { NSPasteboard.general.clearContents(); if let saved { NSPasteboard.general.setString(saved, forType: .string) } }
        let result = try await web.webView.evaluateJavaScript("""
            const input=document.querySelectorAll('.md-table-cell-input')[2];
            input.closest('.md-editable-table').tableController.activate(1,0);
            input.setSelectionRange(0,2);
            input.dispatchEvent(new MouseEvent('mousedown',{button:2,bubbles:true,cancelable:true}));
            input.dispatchEvent(new MouseEvent('contextmenu',{button:2,clientX:180,clientY:150,bubbles:true,cancelable:true}));
            const menu=document.querySelector('.md-table-toolbar'),rect=menu.getBoundingClientRect();
            const style=getComputedStyle(input);
            ({start:input.selectionStart,end:input.selectionEnd,x:rect.x,y:rect.y,background:style.backgroundColor,shadow:style.boxShadow});
            """) as? [String: Any]
        #expect(result?["start"] as? Int == 0 && result?["end"] as? Int == 2)
        #expect(result?["x"] as? Double == 180 && result?["y"] as? Double == 150)
        #expect(result?["background"] as? String == "rgba(0, 0, 0, 0)")
        #expect(result?["shadow"] as? String == "none")
        _ = try await web.webView.evaluateJavaScript("document.querySelector('[data-action=copy]').click()")
        try await waitFor("!document.querySelector('.md-editable-table').classList.contains('menu-open')", in: web)
        #expect(await web.flush())
        #expect(NSPasteboard.general.string(forType: .string) == "한글")
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-table-menu-button').click();document.body.dispatchEvent(new MouseEvent('mousedown',{bubbles:true}))")
        #expect(try await web.webView.evaluateJavaScript("!document.querySelector('.md-editable-table').classList.contains('menu-open')") as? Bool == true)
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect(editor.activeScintillaView?.canUndo == false)
    }

    @Test func markdownSurfacesFollowWorkspacePaletteAcrossModeAndAppearanceChanges() async throws {
        let source = "# Theme 한글\n\n본문 **bold**, `code`, [link](../file.md).\n\n```swift\nlet value = 42 // comment\n```\n\n| A | B |\n| --- | --- |\n| one | two |\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        for palette in [EditorThemePalette.dark, .light, .highContrastDark, .highContrastLight, .dark] {
            editor.applyTheme(palette)
            #expect(await editor.synchronizePendingInput())
            let colors = palette.colors
            let expected = String(format: "rgb(%d, %d, %d)", (colors.editor >> 16) & 255, (colors.editor >> 8) & 255, colors.editor & 255)
            for live in [true, false, true] {
                editor.setMarkdownLiveEditingEnabled(live)
                #expect(await editor.synchronizePendingInput())
                let result = try await web.webView.evaluateJavaScript("""
                    ({surfaces:['html','body','#editor','.cm-editor','.cm-scroller'].map(selector=>getComputedStyle(document.querySelector(selector)).backgroundColor),
                      foreground:getComputedStyle(document.querySelector('.cm-content')).color,
                      code:document.querySelector('.md-inline-code')?getComputedStyle(document.querySelector('.md-inline-code')).backgroundColor:null});
                    """) as? [String: Any]
                #expect(result?["surfaces"] as? [String] == Array(repeating: expected, count: 5))
                let background = try #require(web.layer?.backgroundColor).components
                #expect(background?.prefix(3).map { Int(($0 * 255).rounded()) } == [(colors.editor >> 16) & 255, (colors.editor >> 8) & 255, colors.editor & 255])
                let foreground = String(format: "rgb(%d, %d, %d)", (colors.foreground >> 16) & 255, (colors.foreground >> 8) & 255, colors.foreground & 255)
                #expect(result?["foreground"] as? String == foreground)
                #expect(editor.snapshot(for: buffer)?.text == source)
                #expect(editor.activeScintillaView?.canUndo == false)
            }
        }
    }

    @Test func mermaidUsesWorkspaceColorsAfterAppearanceSwitches() async throws {
        let source = "# Theme\n\n본문 `code` and [link](../file.md).\n\n```swift\nlet value = 42\n```\n\n| Task | Status |\n| --- | --- |\n| Design | Ready |\n\n```mermaid\ngraph LR; A[Draft]-->B[Done]\n```\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        for palette in [EditorThemePalette.dark, .light, .highContrastDark, .highContrastLight] {
            editor.applyTheme(palette)
            #expect(await editor.synchronizePendingInput())
            let value = palette.colors.panel
            let expected = String(format: "rgb(%d, %d, %d)", (value >> 16) & 255, (value >> 8) & 255, value & 255)
            try await waitFor("document.querySelector('.md-diagram')?.dataset.state==='ready' && getComputedStyle(document.querySelector('.md-diagram .node rect')).fill==='\(expected)'", in: web)
            #expect(try await web.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.md-inline-code')).backgroundColor===getComputedStyle(document.querySelector('.md-table th')).backgroundColor") as? Bool == true)
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_MARKDOWN_LIVE_SNAPSHOTS"] {
                let image = try await web.webView.takeSnapshot(configuration: nil)
                let data = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
                let root = URL(fileURLWithPath: directory)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try data.write(to: root.appendingPathComponent("theme-\(palette).png"))
            }
            #expect(editor.snapshot(for: buffer)?.text == source)
            #expect(editor.activeScintillaView?.canUndo == false)
        }
    }

    @Test func focusingTableCellsKeepsAllColumnWidthsAndOtherRowsStable() async throws {
        let source = "Before\n\n| 비교 항목 | 기존 Workflow LLM | Callflow 공통 LLM |\n| --- | --- | --- |\n| 노드 구간 | `fyro.scenario.node.llm` | `fyro.node.llm`, frame·activation·execution 식별자 |\n| 노드 입력 | handler가 선별한 guardrail·PIF·MCP·prompt 표현 등 | 전달된 config, event, 실제 참조한 `resolved_variables`. 완성된 모델 요청과는 다름 |\n| 노드 출력 | raw_text·text, 선택적 PIF·schema·cache·skip 필드 | 최종 text·raw_text·structured_output과 별도 response. raw_text도 최종 text와 동일 |\n\nAfter"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let bounds = "Array.from(document.querySelectorAll('.md-table :is(th,td)')).map(e=>{const r=e.getBoundingClientRect();return [r.x,r.y,r.width,r.height]})"
        editor.applyTheme(.dark)
        #expect(await editor.synchronizePendingInput())
        let initial = try #require(try await web.webView.evaluateJavaScript(bounds) as? [[Double]])
        try await capture(web, name: "table-before-focus")
        for index in [9,0,1,5,8,10,11] {
            _ = try await web.webView.callAsyncJavaScript("document.querySelectorAll('.md-table-cell-preview')[index].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}))", arguments: ["index": index], in: nil, contentWorld: .page)
            try await Task.sleep(for: .milliseconds(40))
            #expect(try await web.webView.evaluateJavaScript("document.activeElement.classList.contains('md-table-cell-input')") as? Bool == true)
            let focused = try #require(try await web.webView.evaluateJavaScript(bounds) as? [[Double]])
            if index == 9 { try await capture(web, name: "table-after-focus") }
            #expect(focused.count == initial.count)
            #expect(zip(initial,focused).allSatisfy { a,b in zip(a,b).allSatisfy { abs($0-$1)<0.5 } })
        }
        _ = try await web.webView.evaluateJavaScript("document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect(editor.activeScintillaView?.canUndo == false)
    }

    @Test func commandClickLinksWorksInSourceLiveAndTableWithoutEditing() async throws {
        let source = "# Links\n\n[web](https://example.com/path?q=한글) and [local](../source/a%20b.md#heading)\n\n| A | B |\n| --- | --- |\n| [table](https://example.com/table) | value |\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        editor.setMarkdownDocumentURL(URL(fileURLWithPath: "/tmp/docs/note.md"))
        var opened: [URL] = []
        editor.onOpenMarkdownLink = { opened.append($0) }
        #expect(await editor.synchronizePendingInput())
        for live in [true,false,true] {
            editor.setMarkdownLiveEditingEnabled(live)
            #expect(await editor.synchronizePendingInput())
            let links = try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-link-label').length") as? Int
            #expect((links ?? 0) >= 2)
            if !live {
                #expect(try await web.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.md-link-label')).color!==getComputedStyle(document.querySelector('.md-link-marker')).color && getComputedStyle(document.querySelector('.md-link-marker')).color===getComputedStyle(document.querySelector('.md-link-destination')).color") as? Bool == true)
            }
            #expect(try await web.webView.evaluateJavaScript("(()=>{const link=document.querySelector('.md-link-label');if(!link)return false;const event=new MouseEvent('mousedown',{metaKey:true,button:0,bubbles:true,cancelable:true});link.dispatchEvent(event);link.dispatchEvent(new MouseEvent('click',{metaKey:true,button:0,bubbles:true,cancelable:true}));return event.defaultPrevented})()") as? Bool == true)
            #expect(await editor.synchronizePendingInput())
            #expect(opened.last?.host == "example.com")
        }
        _ = try await web.webView.evaluateJavaScript("Array.from(document.querySelectorAll('.md-link-label')).find(e=>e.textContent==='local')?.dispatchEvent(new MouseEvent('click',{metaKey:true,button:0,bubbles:true,cancelable:true}))")
        #expect(await editor.synchronizePendingInput())
        #expect(opened.last?.isFileURL == true && opened.last?.path == "/tmp/source/a b.md")
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-table-cell-preview a')?.dispatchEvent(new MouseEvent('click',{metaKey:true,button:0,bubbles:true,cancelable:true}))")
        #expect(await editor.synchronizePendingInput())
        #expect(opened.last?.path == "/table")
        let countBeforeCellClick = opened.count
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-editable-table').tableController.activate(1,0);const field=document.activeElement;field.setSelectionRange(2,2);field.dispatchEvent(new MouseEvent('click',{metaKey:true,button:0,bubbles:true,cancelable:true}))")
        #expect(await editor.synchronizePendingInput())
        #expect(opened.last?.path == "/table")
        #expect(opened.count == countBeforeCellClick + 1)
        let count = opened.count
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-link-label')?.dispatchEvent(new MouseEvent('click',{button:0,bubbles:true,cancelable:true}))")
        #expect(await editor.synchronizePendingInput())
        #expect(opened.count == count)
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect(editor.activeScintillaView?.canUndo == false)
    }

    @Test func commandClickHandlesReferencesAutolinksAndIgnoresUnsupportedDestinations() async throws {
        let source = "[ref][id], <https://example.com/auto>, https://example.com/plain, [](empty.md), [bad](javascript:alert), [collapsed][]\n\n[id]: ../ref.md\n[collapsed]: ../collapsed.md\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        editor.setMarkdownDocumentURL(URL(fileURLWithPath: "/tmp/docs/note.md"))
        var opened: [URL] = []
        editor.onOpenMarkdownLink = { opened.append($0) }
        #expect(await editor.synchronizePendingInput())
        _ = try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-link-label').forEach(link=>link.dispatchEvent(new MouseEvent('click',{metaKey:true,bubbles:true,cancelable:true})))")
        #expect(await editor.synchronizePendingInput())
        #expect(opened.map(\.path) == ["/tmp/ref.md", "/auto", "/plain", "/tmp/collapsed.md"])
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect(editor.activeScintillaView?.canUndo == false)
    }

    @Test func markdownUsesCodeMirrorInBothModesAndNativeFilesKeepScintilla() async throws {
        let source = "# Heading\n\nA **bold** word and *italic* with `code`.\n\n- Parent\n  - Child\n\n```swift\nlet value = 42\n```\n\n| A | B |\n| --- | --- |\n| one | two |\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let native = try #require(editor.activeScintillaView)
        #expect(editor.isMarkdownLiveEditingEnabled)
        var info = try await diagnostics(web)
        #expect((info["headings"] as? [[String: Any]])?.first?["size"] as? String == "32px")
        #expect(info["tables"] as? Int == 1)
        #expect(try await web.webView.evaluateJavaScript("Array.from(document.querySelectorAll('.md-list')).map(e=>getComputedStyle(e).paddingLeft)") as? [String] == ["24px", "48px"])
        #expect(try await web.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.cm-scroller')).fontFamily.includes('monospace')") as? Bool == false)
        let rendered = try await web.webView.evaluateJavaScript("Array.from(document.querySelectorAll('.cm-line')).map(e=>({text:e.textContent,classes:e.className}))")
        #expect((info["codeLines"] as? Int ?? 0) > 0, "\(String(describing: rendered)); error=\(web.lastScriptError ?? "none")")
        if let directory = ProcessInfo.processInfo.environment["DUCKPAD_MARKDOWN_LIVE_SNAPSHOTS"] {
            try await Task.sleep(for: .milliseconds(100))
            let image = try await web.webView.takeSnapshot(configuration: nil)
            let data = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent("codemirror-live.png"))
        }
        editor.setMarkdownLiveEditingEnabled(false)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.activeCodeMirrorEditor === web)
        info = try await diagnostics(web)
        #expect(info["live"] as? Bool == false && info["raw"] as? String == source)
        #expect(editor.snapshot(for: buffer)?.text == source && !native.canUndo)
        #expect(editor.applyLanguage(.init(languageID: .plainText, lexerName: "null", indentation: .init(), folding: false, braceMatching: false)))
        #expect(editor.activeCodeMirrorEditor == nil)
        #expect(editor.activeScintillaView === native && native.contentUTF8 == Data(source.utf8))
    }

    @Test func editsPreserveUnicodeMixedLineEndingsAndUndoAcrossModeSwitches() async throws {
        let source = "# 한글 🦆\r\n\r\n**bold**\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let end = (source.replacingOccurrences(of: "\r\n", with: "\n") as NSString).length
        try await dispatch(web, ["changes": ["from": end, "insert": " 한글🦆"]])
        let edited = source + " 한글🦆"
        #expect(editor.snapshot(for: buffer)?.text == edited)
        for live in [false, true, false, true] { editor.setMarkdownLiveEditingEnabled(live) }
        #expect(await editor.synchronizePendingInput())
        #expect((try await diagnostics(web))["raw"] as? String == edited)
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect((try await diagnostics(web))["raw"] as? String == source)
        editor.perform(.redo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == edited)
        #expect((try await diagnostics(web))["raw"] as? String == edited)
    }

    @Test func koreanCompositionCommitsOnceAndReadOnlyBarrierDrainsPostedInput() async throws {
        let source = "# 제목\n\n입력: "
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let start = (source as NSString).length
        _ = try await web.webView.evaluateJavaScript("window.DuckpadEditor.compositionStart()")
        _ = try await web.webView.callAsyncJavaScript("window.DuckpadEditor.dispatch({changes:{from:start,insert:'ㅎ'}})",
            arguments: ["start": start], in: nil, contentWorld: .page)
        _ = try await web.webView.callAsyncJavaScript("window.DuckpadEditor.dispatch({changes:{from:start,to:start+1,insert:'한글'}})",
            arguments: ["start": start], in: nil, contentWorld: .page)
        #expect(editor.snapshot(for: buffer)?.text == source)
        editor.setInputEnabled(false)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source + "한글")
        editor.setInputEnabled(true)
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
    }

    @Test func saveAsWaitsForCodeMirrorInputAndWritesExactOriginalLineEndings() async throws {
        var session = ScratchSession()
        let tab = session.addUntitled()
        try session.changeFileLocation(tabID: tab, binding: nil, title: "live.md")
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore(session: session))
        _ = await workspace.start()
        let buffer = try #require(workspace.activeFileContext()?.buffer.bufferID)
        let source = "# Save\r\n\r\n한글 🦆\n\nEnd"
        let (window, editor, _, web) = try await fixture(source, bufferID: buffer, accept: workspace.acceptEditorEdit)
        defer { editor.invalidate(); window.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-codemirror-save-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileDocumentUseCase(workspace: workspace, editor: editor,
            store: LocalTextFileStore(bookmarkArchiveURL: root.appendingPathComponent("bookmarks.json")))
        _ = try await web.webView.evaluateJavaScript("window.DuckpadEditor.dispatch({changes:{from:window.DuckpadEditor.diagnostics().text.length,insert:' 저장'}})")
        let destination = root.appendingPathComponent("live.md")
        #expect(await files.saveAs(destination) == .saved(tab))
        #expect(try Data(contentsOf: destination) == Data((source + " 저장").utf8))
        #expect(workspace.snapshot().tabs.first?.isDirty == false)
    }

    @Test func finalRecoveryFlushCommitsCompositionBeforeFreezingTheDocument() async throws {
        var session = ScratchSession(); let tab = session.addUntitled()
        try session.changeFileLocation(tabID: tab, binding: nil, title: "recovery.md")
        let workspace = ScratchWorkspaceUseCase(store: InMemorySessionStore(session: session))
        _ = await workspace.start()
        let buffer = try #require(workspace.activeFileContext()?.buffer.bufferID)
        let source = "# Recovery\n\nEnd"
        let (window, editor, _, web) = try await fixture(source, bufferID: buffer, accept: workspace.acceptEditorEdit)
        defer { editor.invalidate(); window.close() }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-codemirror-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LocalRecoveryStore(root: root)
        let recovery = SessionRecoveryUseCase(workspace: workspace, editor: editor, store: store)
        workspace.onChange = { [weak recovery] change in recovery?.workspaceDidChange(change) }
        _ = try await web.webView.evaluateJavaScript("window.DuckpadEditor.compositionStart();window.DuckpadEditor.dispatch({changes:{from:window.DuckpadEditor.diagnostics().text.length,insert:'한글'}})")
        let result = await recovery.flushForTermination()
        if case .failed(let error) = result { Issue.record("Recovery failed: \(error)") }
        let archive = try #require(try await store.loadLatest())
        #expect(archive.archive.buffers[buffer]?.utf8 == Data((source + "한글").utf8))
        #expect(workspace.snapshot().tabs.first?.isDirty == true)
        await recovery.waitForPendingAutosave()
    }

    @Test func multipleCursorsRemainVisibleAndEditTogetherAcrossTheBridge() async throws {
        let source = "one\ntwo\nend"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        _ = try await web.webView.evaluateJavaScript("window.DuckpadEditor.dispatch({selection:{ranges:[{anchor:0,head:0},{anchor:4,head:4}],main:1}})")
        #expect(await editor.synchronizePendingInput())
        #expect(editor.activeScintillaView?.selectionCount == 2)
        try await dispatch(web, ["changes": [["from": 0, "insert": "🦆"], ["from": 4, "insert": "🦆"]]])
        #expect(editor.snapshot(for: buffer)?.text == "🦆one\n🦆two\nend")
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect((try await diagnostics(web))["raw"] as? String == source)
    }

    @Test func sharedPanesUseIndependentModesAndPropagateEditsAndUndo() async throws {
        let source = "# Shared\n\nEnd"
        let (window, editor, buffer, first) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let descriptor = EditorBufferDescriptor(bufferID: buffer, revision: 0)
        editor.setEditorGroupOrientation(.sideBySide)
        editor.assign(descriptor, from: .primary, to: .secondary, cloning: true)
        editor.display(descriptor, in: .secondary)
        editor.activateEditorGroup(.secondary)
        let second = try #require(editor.activeCodeMirrorEditor)
        #expect(first !== second)
        for _ in 0..<400 {
            if (try? await second.webView.evaluateJavaScript("!!document.querySelector('.cm-editor')")) as? Bool == true { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        editor.setMarkdownLiveEditingEnabled(false)
        #expect(await editor.synchronizePendingInput())
        #expect((try await diagnostics(first))["live"] as? Bool == true)
        #expect((try await diagnostics(second))["live"] as? Bool == false)
        try await dispatch(second, ["changes": ["from": (source as NSString).length, "insert": " 한글"]])
        #expect(await editor.synchronizePendingInput())
        #expect((try await diagnostics(first))["raw"] as? String == source + " 한글")
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect((try await diagnostics(first))["raw"] as? String == source)
        #expect((try await diagnostics(second))["raw"] as? String == source)
    }

    @Test(arguments: [false, true]) func repeatedChecklistBackspacePreservesDocumentAndScroll(rapid: Bool) async throws {
        let prefix = (0..<70).map { "Paragraph \($0)\n" }.joined() + "\n"
        let item = "- [ ] ㅁㄴㅇㅁㄴㅇ"
        let suffix = "\n\n" + (0..<70).map { "After \($0)\n" }.joined()
        let source = prefix + item + suffix
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let end = (prefix + item as NSString).length
        _ = try await web.webView.callAsyncJavaScript("window.DuckpadEditor.dispatch({selection:{anchor:end},scrollIntoView:true});window.DuckpadEditor.focus();await new Promise(r=>setTimeout(r,100));return true",
            arguments: ["end": end], in: nil, contentWorld: .page)
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.cm-scroller').scrollTop=1300")
        try await Task.sleep(for: .milliseconds(80))
        let before = try #require(try await web.webView.evaluateJavaScript("document.querySelector('.cm-scroller').scrollTop") as? Double)
        let generation = (try await diagnostics(web))["generation"] as? Int
        #expect(before > 500)
        for _ in 0..<(item as NSString).length {
            _ = try await web.webView.evaluateJavaScript("document.querySelector('.cm-content').dispatchEvent(new KeyboardEvent('keydown',{key:'Backspace',code:'Backspace',keyCode:8,bubbles:true,cancelable:true}))")
            if !rapid { #expect(await editor.synchronizePendingInput()) }
            let info = try await diagnostics(web)
            if !rapid { #expect(editor.snapshot(for: buffer)?.text == info["raw"] as? String) }
            #expect(info["generation"] as? Int == generation)
            let scroll = try #require(try await web.webView.evaluateJavaScript("document.querySelector('.cm-scroller').scrollTop") as? Double)
            #expect(scroll > before - 150)
        }
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == (try await diagnostics(web))["raw"] as? String)
        #expect((try await diagnostics(web))["raw"] as? String != source)
    }

    @Test func tableCellsEditInPlacePreserveEscapesAndSupportUndo() async throws {
        let source = "# Table\r\n\r\n| Name | Value |\r\n| :--- | ---: |\r\n| **한글** | a \\| b |\r\n\r\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        let generation = (try await diagnostics(web))["generation"] as? Int
        _ = try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table-cell-preview')[2].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}))")
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.classList.contains('md-table-cell-input')") as? Bool == true)
        _ = try await web.webView.evaluateJavaScript("const input=document.activeElement;input.value='새 값 🦆 | 셀';input.setSelectionRange(input.value.length,input.value.length);input.dispatchEvent(new Event('input',{bubbles:true}));")
        #expect(await editor.synchronizePendingInput())
        let expected = source.replacingOccurrences(of: "**한글**", with: "새 값 🦆 \\| 셀")
        #expect(editor.snapshot(for: buffer)?.text == expected)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.classList.contains('md-table-cell-input')") as? Bool == true)
        #expect((try await diagnostics(web))["tables"] as? Int == 1)
        #expect((try await diagnostics(web))["generation"] as? Int == generation)
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect((try await diagnostics(web))["raw"] as? String == source)
        #expect((try await diagnostics(web))["tables"] as? Int == 1)
        _ = try await web.webView.evaluateJavaScript("{const input=document.querySelectorAll('.md-table-cell-input')[2];input.value='';input.setSelectionRange(0,0);input.dispatchEvent(new Event('input',{bubbles:true}));}")
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source.replacingOccurrences(of: "**한글**", with: ""))
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect((try await diagnostics(web))["tables"] as? Int == 1)
        editor.setReadOnly(true, for: buffer)
        #expect(await editor.synchronizePendingInput())
        #expect(try await web.webView.evaluateJavaScript("Array.from(document.querySelectorAll('.md-table-cell-input')).every(e=>e.readOnly)") as? Bool == true)
        #expect(try await web.webView.evaluateJavaScript("Array.from(document.querySelectorAll('.md-table-toolbar button')).every(e=>e.disabled)") as? Bool == true)
    }

    @Test func tableNavigationAddsRowsAndToolbarChangesColumnsWithoutLosingSource() async throws {
        let source = "| A | B |\n| --- | --- |\n| one | two |\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        _ = try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table-cell-preview')[3].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));document.activeElement.dispatchEvent(new KeyboardEvent('keydown',{key:'Tab',bubbles:true,cancelable:true}));")
        #expect(await editor.synchronizePendingInput())
        #expect(try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table tr').length") as? Int == 3)
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.dataset.row") as? String == "2")
        #expect(editor.snapshot(for: buffer)?.text == source.replacingOccurrences(of: "| one | two |", with: "| one | two |\n|  |  |"))
        _ = try await web.webView.evaluateJavaScript("document.querySelector('[data-action=insertColumn]').click()")
        #expect(await editor.synchronizePendingInput())
        #expect(try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table th').length") as? Int == 3)
        _ = try await web.webView.evaluateJavaScript("document.querySelector('[data-action=deleteColumn]').click();document.querySelector('[data-action=deleteRow]').click()")
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect((try await diagnostics(web))["raw"] as? String == source)
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect((try await diagnostics(web))["tables"] as? Int == 1)
        #expect(try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table tr').length") as? Int == 3)
        editor.perform(.redo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
    }

    @Test func tableKoreanCompositionDrainsBeforeSaveAndModeSwitch() async throws {
        let source = "| A | B |\n| --- | --- |\n| one | two |\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        _ = try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table-cell-preview')[2].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));const input=document.activeElement;input.dispatchEvent(new CompositionEvent('compositionstart',{bubbles:true}));input.value='한글';input.dispatchEvent(new Event('input',{bubbles:true}));")
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source.replacingOccurrences(of: "one", with: "한글"))
        editor.setMarkdownLiveEditingEnabled(false)
        #expect(await editor.synchronizePendingInput())
        #expect((try await diagnostics(web))["raw"] as? String == source.replacingOccurrences(of: "one", with: "한글"))
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
    }

    @Test func nativeSelectionAndDeleteCommandsStayInsideTheFocusedTableCell() async throws {
        let source = "| A | B |\n| --- | --- |\n| 한글 🦆 | two |\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        _ = try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table-cell-preview')[2].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}))")
        editor.perform(.selectAll)
        #expect(await editor.synchronizePendingInput())
        #expect(try await web.webView.evaluateJavaScript("document.activeElement.selectionEnd - document.activeElement.selectionStart") as? Int == 5)
        #expect(editor.canPerform(.copy) && editor.canPerform(.cut))
        editor.perform(.delete)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source.replacingOccurrences(of: "한글 🦆", with: ""))
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect((try await diagnostics(web))["tables"] as? Int == 1)
    }

    @Test func tableClipboardCommandsPasteCopyAndCutCellTextWithOneUndo() async throws {
        let board = NSPasteboard.general
        let saved = (board.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
        defer {
            board.clearContents()
            board.writeObjects(saved.map { values in
                let item = NSPasteboardItem()
                for (type, data) in values { item.setData(data, forType: type) }
                return item
            })
        }
        let source = "| A | B |\n| --- | --- |\n| one | two |\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        _ = try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table-cell-preview')[2].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}))")
        board.clearContents(); board.setString("붙여넣기 | 🦆", forType: .string)
        editor.perform(.selectAll); editor.perform(.paste)
        #expect(await editor.synchronizePendingInput())
        let pasted = source.replacingOccurrences(of: "one", with: "붙여넣기 \\| 🦆")
        #expect(editor.snapshot(for: buffer)?.text == pasted)
        editor.perform(.selectAll); editor.perform(.copy)
        #expect(await editor.synchronizePendingInput())
        #expect(board.string(forType: .string) == "붙여넣기 | 🦆")
        editor.perform(.cut)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == source.replacingOccurrences(of: "one", with: ""))
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        #expect(editor.snapshot(for: buffer)?.text == pasted)
        #expect((try await diagnostics(web))["tables"] as? Int == 1)
    }

    @Test func mermaidRendersInlineAndUpdatesBesideItsSourceWithoutChangingBytes() async throws {
        let source = "# Diagram\n\n```mermaid\ngraph LR\n A[Draft] --> B[Review]\n```\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        try await waitFor("!!document.querySelector('.md-diagram svg') && document.querySelector('.md-diagram').dataset.state==='ready'", in: web)
        #expect(editor.snapshot(for: buffer)?.text == source)
        #expect(editor.activeScintillaView?.canUndo == false)
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-diagram-content').dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}))")
        #expect(await editor.synchronizePendingInput())
        #expect((try await diagnostics(web))["codeLines"] as? Int ?? 0 > 0)
        let range = (source as NSString).range(of: "Draft")
        try await dispatch(web, ["changes": ["from": range.location, "to": range.location + range.length, "insert": "Final"]])
        try await waitFor("document.querySelector('.md-diagram')?.dataset.state==='ready' && Array.from(document.querySelectorAll('.md-diagram svg text')).some(e=>e.textContent==='Final')", in: web)
        let edited = source.replacingOccurrences(of: "Draft", with: "Final")
        #expect(editor.snapshot(for: buffer)?.text == edited)
        let body = (edited as NSString).range(of: "graph LR\n A[Final] --> B[Review]")
        try await dispatch(web, ["changes": ["from": body.location, "to": body.location + body.length, "insert": "not a valid diagram"]])
        try await waitFor("document.querySelector('.md-diagram')?.dataset.state==='invalid'", in: web)
        #expect(try await web.webView.evaluateJavaScript("!!document.querySelector('.md-diagram svg')") as? Bool == true)
        editor.perform(.undo)
        #expect(await editor.synchronizePendingInput())
        try await waitFor("document.querySelector('.md-diagram')?.dataset.state==='ready'", in: web)
        editor.setMarkdownLiveEditingEnabled(false)
        #expect(await editor.synchronizePendingInput())
        try await Task.sleep(for: .milliseconds(400))
        #expect(try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-diagram').length") as? Int == 0)
        editor.setMarkdownLiveEditingEnabled(true)
        #expect(await editor.synchronizePendingInput())
        try await waitFor("!!document.querySelector('.md-diagram svg')", in: web)
        #expect(editor.snapshot(for: buffer)?.text == edited)
        #expect(web.lastScriptError == nil)
    }

    @Test func identicalMermaidDiagramsHaveDistinctSVGIDs() async throws {
        let diagram = "```mermaid\ngraph TD; A[Start]-->B[Finish]\n```\n\n"
        let source = diagram + diagram + "End"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        try await waitFor("document.querySelectorAll('.md-diagram svg').length===2", in: web)
        #expect(try await web.webView.evaluateJavaScript("(()=>{const ids=Array.from(document.querySelectorAll('.md-diagram [id]')).map(e=>e.id);return ids.length===new Set(ids).size;})()") as? Bool == true)
        #expect(editor.snapshot(for: buffer)?.text == source)
    }

    @Test func tableUsesCompactContextualControlsAndCanRenderBesideMermaid() async throws {
        let source = "# Project notes\n\nA small table inside the document.\n\n| Task | Status |\n| --- | --- |\n| **Design** | In progress |\n| Review | Ready |\n\n```mermaid\ngraph LR; A[Draft]-->B[Review]-->C[Done]\n```\n\nEnd"
        let (window, editor, buffer, web) = try await fixture(source)
        defer { editor.invalidate(); window.close() }
        #expect(try await web.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.md-table-toolbar')).display") as? String == "none")
        #expect(try await web.webView.evaluateJavaScript("document.querySelector('.md-editable-table').getBoundingClientRect().width < document.querySelector('.cm-content').getBoundingClientRect().width") as? Bool == true)
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-table-menu-button').click()")
        #expect(try await web.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.md-table-toolbar')).display") as? String == "flex")
        _ = try await web.webView.evaluateJavaScript("document.querySelector('.md-editable-table').dispatchEvent(new KeyboardEvent('keydown',{key:'Escape',bubbles:true,cancelable:true}))")
        #expect(try await web.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.md-table-toolbar')).display") as? String == "none")
        try await waitFor("!!document.querySelector('.md-diagram svg')", in: web)
        #expect(editor.snapshot(for: buffer)?.text == source)
        if let directory = ProcessInfo.processInfo.environment["DUCKPAD_MARKDOWN_LIVE_SNAPSHOTS"] {
            let image = try await web.webView.takeSnapshot(configuration: nil)
            let data = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
            let root = URL(fileURLWithPath: directory)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try data.write(to: root.appendingPathComponent("live-diagrams-tables.png"))
        }
        let lightFill = try await web.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.md-diagram .node rect')).fill") as? String
        editor.applyTheme(.dark)
        #expect(await editor.synchronizePendingInput())
        try await waitFor("document.querySelector('.md-diagram')?.dataset.state==='ready'", in: web)
        let darkFill = try await web.webView.evaluateJavaScript("getComputedStyle(document.querySelector('.md-diagram .node rect')).fill") as? String
        #expect(lightFill != darkFill)
        _ = try await web.webView.evaluateJavaScript("document.querySelectorAll('.md-table-cell-preview')[2].dispatchEvent(new MouseEvent('mousedown',{bubbles:true,cancelable:true}));document.querySelector('.md-table-menu-button').click()")
        if let directory = ProcessInfo.processInfo.environment["DUCKPAD_MARKDOWN_LIVE_SNAPSHOTS"] {
            let image = try await web.webView.takeSnapshot(configuration: nil)
            let data = try #require(image.tiffRepresentation.flatMap { NSBitmapImageRep(data: $0) }?.representation(using: .png, properties: [:]))
            try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("live-diagrams-tables-dark.png"))
        }
        #expect(editor.snapshot(for: buffer)?.text == source)
    }
}
