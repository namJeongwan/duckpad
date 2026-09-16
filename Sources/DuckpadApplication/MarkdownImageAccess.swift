import Foundation

/// Persistent image grants are independent of the preview's AppKit lifetime.
@MainActor public protocol MarkdownImageAccess: AnyObject {
    func remember(_ urls: [URL])
    func acquire() -> [URL]
    func release(_ urls: [URL])
}
