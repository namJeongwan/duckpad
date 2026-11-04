import Foundation
import DuckpadApplication
import LanguageServerProtocol

/// Language/server-specific policy. Transport, synchronization, completion edits,
/// cancellation and UI remain in the common client, regardless of this adapter.
public protocol LanguageServerAdapter: Sendable {
    var definition: LanguageServerDefinition { get }
    func initializationOptions(projectRoot: URL) -> LSPAny?
    func configuration(section: String?, scopeURI: String?, projectRoot: URL) -> LSPAny?
}

public extension LanguageServerAdapter {
    func initializationOptions(projectRoot: URL) -> LSPAny? { nil }
    func configuration(section: String?, scopeURI: String?, projectRoot: URL) -> LSPAny? { nil }
}
