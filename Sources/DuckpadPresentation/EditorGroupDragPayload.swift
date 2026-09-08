import DuckpadApplication
import DuckpadDomain
import Foundation

public struct EditorGroupDragPayload: Equatable, Sendable {
    public static let pasteboardType = "com.duckpad.editor-group-tab.v1"
    public static let version = 1
    public static let maximumDataLength = 1_024

    public let tabID: TabID
    public let sourceGroup: EditorGroupID

    public init(tabID: TabID, sourceGroup: EditorGroupID) {
        self.tabID = tabID
        self.sourceGroup = sourceGroup
    }

    public init?(data: Data) {
        guard data.count <= Self.maximumDataLength,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "tabID", "sourceGroup"],
              Self.isCurrentVersion(object["version"]),
              let rawTabID = object["tabID"] as? String,
              Self.isCanonicalUUID(rawTabID),
              let uuid = UUID(uuidString: rawTabID),
              let rawGroup = object["sourceGroup"] as? String,
              let sourceGroup = EditorGroupID(rawValue: rawGroup) else {
            return nil
        }
        tabID = TabID(rawValue: uuid)
        self.sourceGroup = sourceGroup
    }

    public func encodedData() -> Data {
        let object: [String: Any] = [
            "version": Self.version,
            "tabID": tabID.rawValue.uuidString.lowercased(),
            "sourceGroup": sourceGroup.rawValue,
        ]
        return try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    public static func dropOperation(optionPressed: Bool) -> EditorGroupDropOperation {
        optionPressed ? .copy : .move
    }

    private static func isCanonicalUUID(_ value: String) -> Bool {
        value.range(
            of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
            options: .regularExpression
        ) != nil
    }

    private static func isCurrentVersion(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        let type = String(cString: number.objCType)
        guard ["s", "i", "l", "q", "S", "I", "L", "Q"].contains(type) else { return false }
        return number.intValue == Self.version
    }
}
