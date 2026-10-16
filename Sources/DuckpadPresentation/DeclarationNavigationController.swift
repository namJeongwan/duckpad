import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

/// Owns one window's navigation requests and history, never the editing path.
@MainActor
final class DeclarationNavigationController {
    private struct Target {
        let tab: TabSnapshot?
        let url: URL?
        let data: Data
        let match: SymbolNavigationMatch
        var label: String { tab?.fullPath ?? url?.path ?? tab?.title ?? "" }
    }
    private struct Location: Equatable {
        let tab: TabID
        let buffer: EditorBufferDescriptor
        let position: EditorNavigationPosition
    }
    private let workspace: ScratchWorkspaceUseCase
    private weak var editor: (any DeclarationNavigationEditorPort)?
    private let analyzer: any DeclarationAnalyzing
    private let project: (any DeclarationProjectSearching)?
    private let roots: () -> [WorkspaceRoot]
    private let open: (URL) async -> Bool
    private let actionable: () -> Bool
    private weak var anchor: NSView?
    let panel = DeclarationCandidatePanel()
    private var task: Task<Void, Never>?
    private var generation = 0
    private var lookupGeneration = 0
    private struct Lookup {
        let targets: [Target]
        let complete: Bool
        let localMatch: Bool
    }
    private struct HoverResult {
        let capture: DocumentIntelligenceCapture
        let range: Range<Int>
        let roots: [WorkspaceRoot]
        let epoch: Int
        let expires: ContinuousClock.Instant
        let lookup: Lookup
    }
    private var hoverResult: HoverResult?
    private struct Transition {
        let request: Int
        let tab: TabID?
        let path: String?
        var settled: Location?
        var observedActivation = false
    }
    private var transition: Transition?
    private var backward: [Location] = [], forward: [Location] = []
    var canGoBack: Bool { !backward.isEmpty }
    var canGoForward: Bool { !forward.isEmpty }
    var isAvailable: Bool { actionable() && editor?.activeDocumentIntelligenceBuffer != nil }

    init(workspace: ScratchWorkspaceUseCase, editor: (any DeclarationNavigationEditorPort)?,
         project: (any DeclarationProjectSearching)?, analyzer: any DeclarationAnalyzing = BuiltinDeclarationAnalyzer(),
         anchor: NSView, roots: @escaping () -> [WorkspaceRoot], actionable: @escaping () -> Bool,
         open: @escaping (URL) async -> Bool) {
        self.workspace = workspace; self.editor = editor; self.project = project; self.analyzer = analyzer
        self.anchor = anchor; self.roots = roots; self.open = open; self.actionable = actionable
    }
    deinit { task?.cancel() }
    func cancel(clearLookup: Bool = true) {
        generation += 1; task?.cancel(); task = nil; transition = nil; panel.dismiss()
        editor?.clearDeclarationHover()
        if clearLookup { lookupGeneration += 1; hoverResult = nil }
    }
    func workspaceChanged(_ change: WorkspaceChange) {
        if change.kind == .persistence { return }
        lookupGeneration += 1; hoverResult = nil; editor?.clearDeclarationHover()
        // No scanning, buffer copies, or history dictionaries on ordinary typing.
        if task != nil || panel.isShown {
            var expectedActivation = false
            if var pending = transition, pending.request == generation, !pending.observedActivation,
               let active = change.snapshot.tabs.first(where: \.isActive),
               pending.tab.map({ $0 == active.id }) ?? (active.fullPath == pending.path) {
                switch change.kind {
                case .activeTabChanged, .tabInserted:
                    pending.observedActivation = true
                    pending.settled = currentLocation()
                    transition = pending
                    expectedActivation = true
                default: break
                }
            }
            if !expectedActivation { cancel() }
        }
        switch change.kind {
        case .reset, .tabRemoved, .tabsRemoved:
            let buffers = Dictionary(uniqueKeysWithValues: change.snapshot.tabs.map { ($0.id, $0.buffer.bufferID) })
            backward.removeAll { buffers[$0.tab] != $0.buffer.bufferID }
            forward.removeAll { buffers[$0.tab] != $0.buffer.bufferID }
        default: break
        }
    }
    private func finish(_ request: Int) {
        guard generation == request else { return }
        task = nil; transition = nil
    }
    private func beginTransition(tab: TabID?, path: String?, request: Int) {
        let location = currentLocation()
        transition = Transition(request: request, tab: tab, path: path,
                                settled: location?.tab == tab ? location : nil)
    }
    private func transitionIsCurrent(_ request: Int) -> Bool {
        guard generation == request, !Task.isCancelled, actionable(),
              let pending = transition, pending.request == request,
              let settled = pending.settled, let current = currentLocation(), current == settled,
              let active = workspace.snapshot().tabs.first(where: \.isActive), active.id == settled.tab else { return false }
        return pending.tab.map { $0 == active.id } ?? (active.fullPath == pending.path)
    }
    private func currentLocation() -> Location? {
        guard let editor, let buffer = editor.activeDocumentIntelligenceBuffer,
              let tab = workspace.snapshot().tabs.first(where: { $0.buffer == buffer }),
              let position = (editor as? any EditorNavigationPort)?.navigationPosition else { return nil }
        return Location(tab: tab.id, buffer: buffer, position: position)
    }
    private func current(_ capture: DocumentIntelligenceCapture, request: Int) -> Bool {
        generation == request && !Task.isCancelled && actionable() && editor?.declarationContextIsCurrent(capture) == true
    }
    private func cachedHover(_ capture: DocumentIntelligenceCapture, offset: Int) -> Lookup? {
        guard let cached = hoverResult, cached.epoch == lookupGeneration,
              ContinuousClock.now < cached.expires, cached.roots == roots(),
              cached.capture.buffer == capture.buffer, cached.capture.contextID == capture.contextID,
              cached.capture.languageID == capture.languageID, cached.capture.utf8 == capture.utf8,
              cached.range.contains(offset) else { return nil }
        return cached.lookup
    }

    /// The same bounded target query serves hover and activation. No history/UI is changed here.
    func resolveHover(_ capture: DocumentIntelligenceCapture, at offset: Int, index: DeclarationIndex) async -> Bool {
        guard actionable(), let range = index.navigationRange(at: offset) else { return false }
        if let cached = cachedHover(capture, offset: offset) { return !cached.targets.isEmpty }
        let epoch = lookupGeneration, rootSnapshot = roots()
        let lookup = await lookup(capture, index: index, offset: offset, kind: .declarations, roots: rootSnapshot, epoch: epoch)
        guard !Task.isCancelled, lookupGeneration == epoch, roots() == rootSnapshot else { return false }
        hoverResult = HoverResult(capture: capture, range: range, roots: rootSnapshot, epoch: epoch,
                                  expires: ContinuousClock.now.advanced(by: .seconds(2)), lookup: lookup)
        return !lookup.targets.isEmpty
    }

    private func lookup(_ capture: DocumentIntelligenceCapture, index: DeclarationIndex, offset: Int,
                        kind: SymbolNavigationKind, roots rootSnapshot: [WorkspaceRoot], epoch: Int) async -> Lookup {
        guard let editor, let name = index.word(at: offset) else { return Lookup(targets: [], complete: index.isComplete, localMatch: false) }
        func valid() -> Bool { !Task.isCancelled && lookupGeneration == epoch && roots() == rootSnapshot }
        let source = workspace.snapshot().tabs.first { $0.buffer == capture.buffer }
        guard source != nil, valid() else { return Lookup(targets: [], complete: false, localMatch: false) }
        let qualified = index.isQualified(at: offset)
        let local = index.matches(named: name, kind: kind, at: qualified ? nil : offset)
        var targets = local.prefix(200).map { Target(tab: source, url: nil, data: capture.utf8, match: $0) }
        let localMatch = kind == .declarations && !targets.isEmpty && !qualified
        var complete = index.isComplete && local.count <= 200
        if kind == .references || targets.isEmpty || qualified {
            let tabs = workspace.snapshot().tabs
            var bytes = 0
            for tab in tabs where tab.buffer.bufferID != capture.buffer.bufferID {
                guard valid() else { return Lookup(targets: [], complete: false, localMatch: false) }
                guard bytes < 16 * 1_024 * 1_024, targets.count < 200 else { complete = false; break }
                guard let language = editor.declarationLanguage(for: tab.buffer) ?? DeclarationLanguage.forFilename(tab.fullPath ?? tab.title),
                      DeclarationLanguage.isCompatible(language, capture.languageID.rawValue) else { continue }
                guard let data = editor.declarationContent(for: tab.buffer, maximumBytes: min(DeclarationIndex.maximumBytes, 16 * 1_024 * 1_024 - bytes)) else { complete = false; continue }
                bytes += data.count
                let other = await analyzer.index(utf8: data, language: language)
                let matches = other.matches(named: name, kind: kind)
                complete = complete && other.isComplete && matches.count <= 200 - targets.count
                targets += matches.prefix(max(0, 200 - targets.count)).map { Target(tab: tab, url: nil, data: data, match: $0) }
            }
            if let project, !rootSnapshot.isEmpty, targets.count < 200, valid() {
                let result = await project.find(name: name, language: capture.languageID.rawValue, kind: kind, roots: rootSnapshot, excludingPaths: Set(tabs.compactMap(\.fullPath)))
                complete = complete && result.isComplete && result.matches.count <= 200 - targets.count
                targets += result.matches.prefix(max(0, 200 - targets.count)).map { Target(tab: nil, url: $0.url, data: $0.utf8, match: $0.match) }
            } else if !rootSnapshot.isEmpty, targets.count >= 200 { complete = false }
        }
        return Lookup(targets: targets, complete: complete && valid(), localMatch: localMatch)
    }

    func goToDeclaration(at clickedOffset: Int? = nil) { navigate(kind: .declarations, at: clickedOffset) }
    func findReferences() { navigate(kind: .references, at: nil) }

    private func navigate(kind: SymbolNavigationKind, at clickedOffset: Int?) {
        guard isAvailable, let editor else { return }
        cancel(clearLookup: false)
        guard let capture = editor.captureDocumentIntelligence(maximumBytes: DeclarationIndex.maximumBytes),
              let origin = currentLocation() else { showMessage("Declaration navigation is unavailable for this document."); return }
        let offset = clickedOffset ?? capture.caretUTF8, request = generation, epoch = lookupGeneration
        let rootSnapshot = roots()
        let cached = kind == .declarations ? cachedHover(capture, offset: offset) : nil
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finish(request) }
            let result: Lookup
            if let cached { result = cached }
            else {
                let index = await analyzer.index(utf8: capture.utf8, language: capture.languageID.rawValue)
                guard current(capture, request: request) else { return }
                result = await lookup(capture, index: index, offset: offset, kind: kind, roots: rootSnapshot, epoch: epoch)
            }
            guard current(capture, request: request), lookupGeneration == epoch, roots() == rootSnapshot else { return }
            if result.targets.isEmpty {
                if kind == .references { showMessage(result.complete ? "No reference candidates found." : "Some files could not be searched. No reference candidates found.") }
                else { showMessage(result.complete ? "No declaration found." : "Some files could not be searched. No declaration found.") }
                return
            }
            if kind == .declarations, result.targets.count == 1, result.complete, result.localMatch {
                await reveal(result.targets[0], origin: origin, capture: capture, request: request)
            } else if let anchor {
                let choices = result.targets
                panel.present(rows: choices.map { .init(name: $0.match.name, detail: "\($0.label):\($0.match.line)", preview: $0.match.preview(in: $0.data)) }, complete: result.complete, anchor: anchor, kind: kind)
                panel.onChoose = { [weak self] selected in
                    guard let self, choices.indices.contains(selected) else { return }
                    self.task = Task { @MainActor [weak self] in
                        guard let self else { return }
                        defer { self.finish(request) }
                        await self.reveal(choices[selected], origin: origin, capture: capture, request: request)
                    }
                }
            }
        }
    }
    private func reveal(_ target: Target, origin: Location, capture: DocumentIntelligenceCapture, request: Int) async {
        guard current(capture, request: request), let editor else { return }
        beginTransition(tab: target.tab?.id, path: target.url?.path, request: request)
        if let tab = target.tab {
            guard workspace.snapshot().tabs.contains(where: { $0.id == tab.id && $0.buffer == tab.buffer }),
                  case .applied = await workspace.activate(tabID: tab.id) else {
                if generation == request && !Task.isCancelled { showMessage("The document changed. Try navigation again.") }
                return
            }
        } else if let url = target.url {
            guard roots().contains(where: { $0.isAvailable && url.path.hasPrefix($0.canonicalPath + "/") }), await open(url) else { return }
        }
        guard transitionIsCurrent(request),
              let active = editor.activeDocumentIntelligenceBuffer,
              editor.declarationContent(for: active, maximumBytes: DeclarationIndex.maximumBytes) == target.data else {
            if generation == request { showMessage("The document changed. Try navigation again.") }; return
        }
        backward.append(origin); if backward.count > 100 { backward.removeFirst() }; forward.removeAll()
        editor.revealDeclaration(target.match.range); editor.focus()
    }
    func moveHistory(back: Bool) {
        guard actionable(), let origin = currentLocation() else { return }
        cancel(); let request = generation
        guard let destination = back ? backward.last : forward.last else { return }
        task = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { finish(request) }
            beginTransition(tab: destination.tab, path: nil, request: request)
            guard case .applied = await workspace.activate(tabID: destination.tab), transitionIsCurrent(request),
                  let nav = editor as? any EditorNavigationPort,
                  let position = nav.navigationPosition else { return }
            let sameRevision = editor?.activeDocumentIntelligenceBuffer == destination.buffer
            let moved = sameRevision
                ? nav.goTo(utf8Offset: destination.position.utf8Offset, in: position.contextID)
                : nav.goTo(line: min(destination.position.line, position.lineCount), column: destination.position.column, in: position.contextID)
            if moved, (back ? backward.last : forward.last) == destination {
                if let offset = nav.navigationPosition?.utf8Offset {
                    editor?.revealDeclaration(.init(location: offset, length: 0))
                }
                if back { backward.removeLast(); forward.append(origin); if forward.count > 100 { forward.removeFirst() } }
                else { forward.removeLast(); backward.append(origin); if backward.count > 100 { backward.removeFirst() } }
            }
        }
    }
    private func showMessage(_ key: String) {
        guard let anchor else { return }
        panel.present(rows: [], complete: true, anchor: anchor)
        // Use a visible, localized result instead of silently doing nothing.
        panel.showMessage(L10n.text(key))
    }
}
