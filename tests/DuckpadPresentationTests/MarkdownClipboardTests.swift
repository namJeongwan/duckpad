import Foundation
@testable import DuckpadPresentation
import Testing

@Suite @MainActor
struct MarkdownClipboardTests {
    @Test func rendersHeadingsNestedListsTablesAndInlineFormatting() throws {
        let source = """
        ## 1. RiLACC

        ### 1. Fyro
        - 부하테스트
            - ASTD 모델 없이 **300 채널**
                - AEC/AGC 제거

        | 기능 | 상태 |
        | --- | --- |
        | TTS | *확인* |

        [link](https://example.com) `code` ~~old~~

        ```python
        print("<hello>")
        ```
        """
        let data = try #require(MarkdownClipboardRenderer().html(for: source))
        let html = String(decoding: data, as: UTF8.self)
        #expect(html.contains("<h2 style="))
        #expect(html.contains(">1. RiLACC</h2>"))
        #expect(!html.contains("## 1. RiLACC"))
        #expect(html.components(separatedBy: "<ul ").count == 4)
        #expect(html.contains("<table style="))
        #expect(html.contains("<strong>300 채널</strong>"))
        #expect(html.contains("<em>확인</em>"))
        #expect(html.contains("<s>old</s>"))
        #expect(html.contains("href=\"https://example.com\""))
        #expect(html.contains("&lt;hello&gt;"))
        #expect(html.contains("font-size:11pt"))
    }

    @Test func untrustedSourceCannotEmitExecutableHTMLOrLoadResources() throws {
        let renderer = MarkdownClipboardRenderer()
        let source = """
        <script>alert(1)</script>
        <img src="file:///private/secret" onerror="alert(1)">

        [bad](javascript:alert%281%29) [local](file:///private/secret)
        ![remote image](https://example.com/tracker.png)
        ![nested **alt**](https://example.com/image.png)
        [safe](mailto:hello@example.com)
        '\\'); throw new Error('injection'); //
        """
        let html = String(decoding: try #require(renderer.html(for: source)), as: UTF8.self)
        #expect(!html.contains("<script"))
        #expect(!html.contains("<img"))
        #expect(!html.contains("href=\"file:"))
        #expect(!html.contains("href=\"javascript:"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("remote image"))
        #expect(html.contains("href=\"mailto:hello@example.com\""))
        #expect(renderer.html(for: "# Next") != nil)
    }

    @Test func boundsRejectOversizedInputAndCRLFParsesNormally() throws {
        let renderer = MarkdownClipboardRenderer()
        #expect(renderer.html(for: "") == nil)
        #expect(renderer.html(for: String(repeating: "x", count: MarkdownClipboardRenderer.maximumSourceBytes + 1)) == nil)
        let html = String(decoding: try #require(renderer.html(for: "# 한글 🙂\r\n\r\n1. first\r\n2. second\r\n")), as: UTF8.self)
        #expect(html.contains(">한글 🙂</h1>"))
        #expect(html.contains("<ol style="))
    }
}
