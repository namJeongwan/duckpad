import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
@testable import DuckpadPresentation
import Testing

@Suite(.serialized)
struct DocumentStatusBarTests {
    @Test @MainActor func statusUpdatesStayWithinInteractionBudget() {
        _ = NSApplication.shared
        let bar = DocumentStatusBarView(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        bar.install(language: StatusBarButton(title: "Swift", target: nil, action: nil),
                    encoding: StatusBarButton(title: "UTF-8", target: nil, action: nil))
        for width in [CGFloat(420), 1920] {
            bar.frame.size.width = width
            var samples: [Double] = []
            for i in 0..<220 {
                let start = CFAbsoluteTimeGetCurrent()
                bar.apply(.init(length: 90000000 + i, lines: 1000000, line: 99999, column: 1000 + i,
                                selectedCharacters: 0, selectedLines: 0, isOvertype: false))
                bar.layoutSubtreeIfNeeded()
                if i >= 20 { samples.append((CFAbsoluteTimeGetCurrent() - start) * 1000) }
            }
            samples.sort()
            let p95 = samples[Int(Double(samples.count) * 0.95)]
            print("Status bar apply+layout width=\(Int(width)) p95=\(p95)ms")
            // Status chrome must leave most of the 50ms interaction budget to the editor.
            #expect(p95 < 10)
        }
    }

    @Test(arguments: AppLanguage.allCases.filter { $0 != .system })
    @MainActor func overflowPreservesInformationAndActionsAcrossResize(language: AppLanguage) async throws {
        _ = NSApplication.shared
        let catalog = LocalizationCatalog(language: language)
        let bar = DocumentStatusBarView(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        let languageButton = StatusBarButton(title: "Plain Text", target: nil, action: nil)
        let encoding = StatusBarButton(title: "UTF-8", target: nil, action: nil)
        let target = StatusActionTarget()
        bar.install(language: languageButton, encoding: encoding)
        bar.modeButton.target = target
        bar.modeButton.action = #selector(StatusActionTarget.execute(_:))
        bar.apply(.init(length: 123456789, lines: 987654, line: 12345, column: 12345,
                        selectedCharacters: 987654, selectedLines: 1234, isOvertype: false), catalog: catalog)
        bar.refreshLocalization(catalog: catalog)
        bar.layoutSubtreeIfNeeded()
        #expect(!bar.overflowButton.isHidden)
        #expect(bar.overflowButton.accessibilityLabel() == catalog.text("More document information"))
        let menu = bar.overflowMenu()
        #expect(menu.items.contains { $0.title == bar.lengthLabel.stringValue })
        #expect(menu.items.contains { $0.title == bar.positionButton.accessibilityValue() as? String })
        let mode = try #require(menu.items.first { $0.representedObject as? NSButton === bar.modeButton })
        #expect(mode.isEnabled)
        #expect(NSApp.sendAction(try #require(mode.action), to: mode.target, from: mode))
        await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        #expect(target.count == 1)
        bar.modeButton.isEnabled = false
        #expect(bar.overflowMenu().items.first { $0.representedObject as? NSButton === bar.modeButton }?.isEnabled == false)
        #expect(bar.menuAnchor(for: bar.lineEndingButton) === bar.overflowButton)
        bar.frame.size.width = 1920
        bar.needsLayout = true
        bar.layoutSubtreeIfNeeded()
        #expect(bar.overflowButton.isHidden)
        #expect(!bar.lengthLabel.isHidden)
        #expect(!bar.lineEndingButton.isHidden)
        #expect(bar.positionButton.title == bar.positionButton.accessibilityValue() as? String)
        #expect(bar.menuAnchor(for: bar.lineEndingButton) === bar.lineEndingButton)
        #expect(languageButton.frame.minX - bar.terminalButton.frame.maxX <= 8)
    }

    @Test @MainActor func narrowStatusBarPrioritizesPositionAndEncoding() {
        _ = NSApplication.shared
        let bar = DocumentStatusBarView(frame: NSRect(x: 0, y: 0, width: 420, height: 24))
        let language = StatusBarButton(title: "Swift", target: nil, action: nil)
        let encoding = StatusBarButton(title: "UTF-8", target: nil, action: nil)
        bar.install(language: language, encoding: encoding)
        bar.layoutSubtreeIfNeeded()
        #expect(bar.lengthLabel.isHidden)
        #expect(!bar.positionButton.isHidden)
        #expect(bar.positionButton.frame.width >= 110)
        #expect(!encoding.isHidden)
        #expect(encoding.frame.width >= 55)
    }

    @Test(arguments: [CGFloat(420), 720, 1080, 1920])
    @MainActor func familiarStatusFieldsKeepTheirOrderInBothAppearances(width: CGFloat) throws {
        _ = NSApplication.shared
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let bar = DocumentStatusBarView(frame: NSRect(x: 0, y: 0, width: width, height: 24))
            let window = NSWindow(contentRect: bar.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: appearance)
            window.contentView = bar
            defer { window.contentView = nil; window.close() }
            let language = StatusBarButton(title: "Text", target: nil, action: nil)
            let encoding = StatusBarButton(title: "UTF-8", target: nil, action: nil)
            bar.install(language: language, encoding: encoding)
            bar.apply(.init(length: 27, lines: 1, line: 1, column: 10,
                            selectedCharacters: 0, selectedLines: 0, isOvertype: false))
            bar.layoutSubtreeIfNeeded()
            let fields: [NSView] = [language, bar.lengthLabel, bar.positionButton, bar.lineEndingButton, encoding, bar.modeButton].filter { !$0.isHidden }
            #expect(fields.map(\.frame.minX) == fields.map(\.frame.minX).sorted())
            #expect(fields.allSatisfy { bar.bounds.contains($0.frame) })
            #expect(language.frame.width <= 100)
            #expect(language.frame.minX > bar.terminalButton.frame.maxX)
            #expect(language.frame.minX - bar.terminalButton.frame.maxX <= 8)
            #expect(zip(fields, fields.dropFirst()).allSatisfy { $0.frame.maxX <= $1.frame.minX })
            #expect(bar.lengthLabel.stringValue == "Length: 27   Lines: 1")
            #expect(bar.positionButton.accessibilityValue() as? String == "Ln: 1   Col: 10   Sel: 0 | 0")
            #expect(bar.lineEndingButton.title == "Unix (LF)")
            #expect(bar.modeButton.title == "INS")
            let event = try #require(NSEvent.mouseEvent(
                with: .mouseMoved, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                clickCount: 0, pressure: 0
            ))
            for button in [bar.terminalButton, language, bar.positionButton, bar.lineEndingButton, encoding, bar.modeButton] {
                button.mouseExited(with: event)
                let resting = button.layer?.backgroundColor
                button.mouseEntered(with: event)
                let hovered = button.layer?.backgroundColor
                #expect(hovered != resting)
                let hoverCGColor = try #require(hovered)
                let hoverColor = try #require(NSColor(cgColor: hoverCGColor)?.usingColorSpace(.deviceRGB))
                // Contrast follows the hosted window, even when the system
                // appearance differs from this test's explicit appearance.
                #expect(appearance == .aqua ? hoverColor.redComponent < 0.5 : hoverColor.redComponent > 0.5)
                button.highlight(true)
                #expect(button.layer?.backgroundColor != hovered)
                button.highlight(false)
                button.isEnabled = false
                #expect(button.layer?.backgroundColor == resting)
                button.isEnabled = true
                button.mouseExited(with: event)
                #expect(button.layer?.backgroundColor == resting)
            }
            language.mouseEntered(with: event)
            if let directory = ProcessInfo.processInfo.environment["DUCKPAD_CHROME_TEST_IMAGES"] {
                let bitmap = try #require(bar.bitmapImageRepForCachingDisplay(in: bar.bounds))
                bar.cacheDisplay(in: bar.bounds, to: bitmap)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                let destination = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try png.write(to: destination.appendingPathComponent("status-\(Int(width))-\(appearance == .aqua ? "light" : "dark").png"))
            }
        }
    }
}

@MainActor private final class StatusActionTarget: NSObject {
    var count = 0
    @objc func execute(_ sender: Any?) { count += 1 }
}
