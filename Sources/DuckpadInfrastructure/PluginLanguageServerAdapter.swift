import Foundation
import DuckpadApplication
import DuckpadDomain
import LanguageServerProtocol

public struct PluginLanguageServerAdapter: LanguageServerAdapter {
    public let definition: LanguageServerDefinition
    private let server: LanguageServiceServer
    private let interpreterPath: String?
    public init(definition: LanguageServerDefinition, server: LanguageServiceServer, interpreterPath: String?) {
        self.definition = definition; self.server = server; self.interpreterPath = interpreterPath
    }
    private func render(_ value: LanguageServiceValue?, root: URL) -> LSPAny? {
        guard let value else { return nil }
        switch value {
        case .string("${interpreter}"): return interpreterPath.map(LSPAny.string)
        case .string("${projectRoot}"): return .string(root.path)
        case .object(let object): return .hash(object.compactMapValues { render($0, root: root) })
        case .array(let values): return .array(values.compactMap { render($0, root: root) })
        case .string(let value): return .string(value)
        case .number(let value): return .number(value)
        case .bool(let value): return .bool(value)
        case .null: return .null
        }
    }
    public func initializationOptions(projectRoot: URL) -> LSPAny? { render(server.initializationOptions, root: projectRoot) }
    public func configuration(section: String?, scopeURI: String?, projectRoot: URL) -> LSPAny? {
        guard var value = render(server.configuration, root: projectRoot) else { return nil }
        for component in (section ?? "").split(separator: ".") {
            guard case .hash(let object) = value, let next = object[String(component)] else { return nil }
            value = next
        }
        return value
    }
}
