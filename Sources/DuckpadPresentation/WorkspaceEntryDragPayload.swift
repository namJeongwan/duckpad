import Foundation
import DuckpadApplication

/// Keep workspace identity so drops use the existing scoped file-read path.
struct WorkspaceEntryDragPayload: Codable, Equatable, Sendable {
    static let pasteboardType = "com.duckpad.workspace-entry.v1"
    static let maximumDataLength = 16_384
    let version: Int
    let entry: WorkspaceBrowserEntry

    init(entry: WorkspaceBrowserEntry) { version = 1; self.entry = entry }
    init?(data: Data) {
        guard data.count <= Self.maximumDataLength,
              let value = try? JSONDecoder().decode(Self.self, from: data),
              value.version == 1, value.entry.kind == .file,
              !value.entry.relativePath.isEmpty, !value.entry.relativePath.hasPrefix("/"),
              !value.entry.relativePath.contains("\0"),
              !value.entry.relativePath.split(separator: "/").contains("..") else { return nil }
        self = value
    }
    func encodedData() -> Data? { try? JSONEncoder().encode(self) }
}
