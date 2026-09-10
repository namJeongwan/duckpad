import AppKit
import DuckpadApplication
import DuckpadDomain

@MainActor
public protocol OpenDocumentComparePresenting: AnyObject {
    var hasPresentedSnapshot: Bool { get }
    var restoresEditorFocusAfterDismissal: Bool { get }
    func chooseTarget(
        source: TabSnapshot,
        candidates: [TabSnapshot],
        attachedTo window: NSWindow?
    ) async -> TabID?
    func present(
        _ content: OpenDocumentCompareContent,
        attachedTo window: NSWindow?,
        isCurrent: @escaping @MainActor () -> Bool
    ) async throws
    func presentFailure(_ error: OpenDocumentComparison.Error, attachedTo window: NSWindow?)
    func cancelOutstandingComparisons()
}

public extension OpenDocumentComparePresenting {
    var hasPresentedSnapshot: Bool { false }
    var restoresEditorFocusAfterDismissal: Bool { true }
    func presentFailure(_ error: OpenDocumentComparison.Error, attachedTo window: NSWindow?) {}
    func cancelOutstandingComparisons() {}
}
