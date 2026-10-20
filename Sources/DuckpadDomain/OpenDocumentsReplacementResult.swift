import Foundation

public struct OpenDocumentReplacement: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case replaced(Int)
        case noChanges
        case readOnly
        case unavailable
        case changed
        case limitExceeded
        case timedOut
        case cancelled
    }
    public let tabID: TabID
    public let title: String
    public let generatedTitle: GeneratedDocumentTitle?
    public let status: Status
    public init(tabID: TabID, title: String, status: Status, generatedTitle: GeneratedDocumentTitle? = nil) {
        self.tabID = tabID; self.title = title; self.status = status; self.generatedTitle = generatedTitle
    }
}

public struct OpenDocumentsReplacementResult: Equatable, Sendable {
    public let documents: [OpenDocumentReplacement]
    public let wasCancelled: Bool
    public init(documents: [OpenDocumentReplacement], wasCancelled: Bool) {
        self.documents = documents; self.wasCancelled = wasCancelled
    }
    public var replacementCount: Int {
        documents.reduce(0) { count, document in
            if case .replaced(let replacements) = document.status { return count + replacements }
            return count
        }
    }
    public var changedDocumentCount: Int {
        documents.filter { if case .replaced = $0.status { return true }; return false }.count
    }
    public var skippedDocumentCount: Int {
        documents.filter { switch $0.status { case .replaced, .noChanges: return false; default: return true } }.count
    }
}
