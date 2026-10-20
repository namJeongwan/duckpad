import AppKit
import DuckpadDomain
import Testing
@testable import DuckpadPresentation

@Suite(.serialized) @MainActor
struct SearchResultLayoutTests {
    @Test func longFileNamesAndDirectoriesStayInsideTheirOwnRow() throws {
        _ = NSApplication.shared
        let host = NSView(frame: .init(x: 0, y: 0, width: 420, height: 160))
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        let cell = SearchResultCell(frame: .zero)
        cell.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(cell)
        NSLayoutConstraint.activate([
            cell.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            cell.topAnchor.constraint(equalTo: host.topAnchor),
            cell.widthAnchor.constraint(equalToConstant: 420),
            cell.heightAnchor.constraint(equalToConstant: 28),
        ])
        cell.apply(title: String(repeating: "한글-file-", count: 40) + "\nname.swift",
                   detail: "/" + String(repeating: "long-directory/", count: 30) + "name.swift",
                   project: String(repeating: "workspace-", count: 20), query: "한글")
        host.layoutSubtreeIfNeeded()
        #expect(cell.bounds.width == 420 && cell.bounds.height == 28)
        for field in cell.subviews.compactMap({ $0 as? NSTextField }) {
            #expect(field.frame.height <= 28)
            #expect(field.frame.minY >= 0 && field.frame.maxY <= 28)
            #expect(field.frame.minX >= 0 && field.frame.maxX <= 420)
        }
        #expect(cell.textField?.attributedStringValue.string.contains("\n") == false)
    }
    @Test(arguments: [420.0, 720.0])
    func longAttributedResultsStayInsideTheirOwnRow(width: Double) throws {
        _ = NSApplication.shared
        let host = NSView(frame: .init(x: 0, y: 0, width: width, height: 160))
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.orderOut(nil) }
        let titles = [String(repeating: #"{"value":"상담 종료 요청 확인","escaped":"\n\t"},"#, count: 24),
                      "first line\nsecond line\rthird line\t상담", "short 상담"]
        for (index, title) in titles.enumerated() {
            let cell = SearchResultLineCell(frame: .zero)
            cell.translatesAutoresizingMaskIntoConstraints = false
            host.addSubview(cell)
            NSLayoutConstraint.activate([
                cell.leadingAnchor.constraint(equalTo: host.leadingAnchor),
                cell.widthAnchor.constraint(equalTo: host.widthAnchor),
                cell.heightAnchor.constraint(equalToConstant: 26),
                cell.topAnchor.constraint(equalTo: host.topAnchor, constant: CGFloat(index * 27)),
            ])
            cell.apply(title: title, detail: "c.json  9", query: .init(pattern: "상담"))
            host.layoutSubtreeIfNeeded()
            let text = try #require(cell.textField)
            #expect(text.lineBreakMode == .byTruncatingTail)
            #expect(text.frame.height <= 26, "A result must not wrap into adjacent rows")
            #expect(text.frame.minY >= 0 && text.frame.maxY <= 26)
            let detail = try #require(cell.subviews.compactMap { $0 as? NSTextField }.first { $0 !== text })
            #expect(text.frame.maxX <= detail.frame.minX - 12)
            #expect(detail.frame.maxX <= width && detail.frame.minX >= 0)
        }
        if let directory = ProcessInfo.processInfo.environment["DUCKPAD_SEARCH_RESULT_SNAPSHOTS"] {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                window.appearance = NSAppearance(named: appearance)
                host.wantsLayer = true
                window.appearance?.performAsCurrentDrawingAppearance {
                    host.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
                }
                host.displayIfNeeded()
                let image = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: image)
                let data = try #require(image.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("results-\(Int(width))-\(appearance.rawValue).png"))
            }
        }
    }
}
