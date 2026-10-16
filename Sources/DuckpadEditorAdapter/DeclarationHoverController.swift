import DuckpadApplication
import DuckpadScintillaBridge
import Foundation

/// One bounded, off-main analysis per document version; pointer motion only looks up a token.
@MainActor
final class DeclarationHoverController {
    private struct Key: Equatable {
        let view: ObjectIdentifier
        let revision: UInt64
        let generation: UInt64
        let language: String
    }
    private let analyzer = BuiltinDeclarationAnalyzer()
    private var cached: (Key, Data, DeclarationIndex)?
    private var task: Task<Void, Never>?
    private weak var owner: DPScintillaEditorView?
    private var request = 0

    func cancel() {
        request += 1
        task?.cancel(); task = nil
        let previous = owner; owner = nil
        previous?.clearDeclarationHover()
    }

    func hover(_ position: UInt, in view: DPScintillaEditorView, language: String?,
               resolve: (@MainActor (Data, DeclarationIndex, Int) async -> Bool)? = nil) {
        if position == NSNotFound {
            if owner === view { cancel() }
            return
        }
        if owner !== view { cancel(); owner = view }
        request += 1
        task?.cancel(); task = nil
        guard let language, DeclarationLanguage.supported.contains(language),
              view.documentByteLength <= DeclarationIndex.maximumBytes else { return }
        let key = Key(view: ObjectIdentifier(view), revision: view.revision,
                      generation: view.declarationContentGeneration, language: language)
        if let cached, cached.0 == key, resolve == nil {
            show(cached.2, at: position, in: view, revision: key.revision)
            return
        }
        let expectedRequest = request
        let cached = cached?.0 == key ? cached : nil
        task = Task { [weak self, weak view, analyzer] in
            // Dwell before background/project work; never scan while sweeping the pointer.
            do { try await Task.sleep(for: .milliseconds(resolve == nil ? 30 : 120)) } catch { return }
            guard let view, !Task.isCancelled, self?.request == expectedRequest,
                  self?.owner === view, view.revision == key.revision,
                  view.declarationContentGeneration == key.generation,
                  view.documentByteLength <= DeclarationIndex.maximumBytes else { return }
            let content = cached?.1 ?? view.contentUTF8
            let index: DeclarationIndex
            if let cached { index = cached.2 }
            else { index = await analyzer.index(utf8: content, language: language) }
            guard let self, !Task.isCancelled, self.request == expectedRequest,
                  self.owner === view, view.revision == key.revision,
                  view.declarationContentGeneration == key.generation else { return }
            self.cached = (key, content, index)
            guard index.navigationRange(at: Int(clamping: position)) != nil else { return }
            let confirmed = if let resolve { await resolve(content, index, Int(clamping: position)) } else { true }
            guard confirmed, !Task.isCancelled, self.request == expectedRequest,
                  self.owner === view, view.revision == key.revision,
                  view.declarationContentGeneration == key.generation else { return }
            self.show(index, at: position, in: view, revision: key.revision, confirmed: resolve != nil)
        }
    }

    private func show(_ index: DeclarationIndex, at position: UInt, in view: DPScintillaEditorView, revision: UInt64, confirmed: Bool = false) {
        if !confirmed {
            guard let name = index.word(at: Int(clamping: position)),
                  !index.candidates(named: name, at: index.isQualified(at: Int(clamping: position)) ? nil : Int(clamping: position)).isEmpty else { return }
        }
        guard let range = index.navigationRange(at: Int(clamping: position)) else { return }
        _ = view.showDeclarationHover(NSRange(location: range.lowerBound, length: range.count),
                                          expectedRevision: revision, expectedPosition: position)
    }
}
