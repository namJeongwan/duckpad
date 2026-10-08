import DuckpadApplication
import Foundation

@MainActor enum NativeDocumentCapture {
    static func read(from editor: any EditorPort, context: FileWorkspaceContext) -> String? {
        guard let reader = editor as? any ExtensionEditorPort,
              let capture = try? reader.captureExtensionInput(tabID: context.tabID,
                  expectedBuffer: context.buffer, scope: .document, maximumBytes: 512 * 1024)
        else { return nil }
        return String(data: capture.scopedUTF8, encoding: .utf8)
    }
}
