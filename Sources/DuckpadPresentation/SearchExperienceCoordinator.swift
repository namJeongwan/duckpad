import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

@MainActor
final class SearchExperienceCoordinator {
    var prepareFileSplit: (() -> ((TabID) -> Void)?)?
    var onOpenResults: ((SearchQuery, MultiFileSearchResults) -> Void)?
    private let workspace: ScratchWorkspaceUseCase
    private let search: SearchWorkspaceUseCase?
    private let folderSearch: FolderSearchUseCase?
    private let folderFileNames: (any FolderFileNameIndexing)?
    private let files: FileDocumentUseCase?
    private let browser: WorkspaceBrowserUseCase?
    private weak var parent: NSWindow?
    private let actionable: () -> Bool
    private let openWorkspace: (WorkspaceBrowserEntry) -> Void
    private let activate: (MultiFileSearchResults.Row.Target) -> Void
    private let onGesture: () -> Void
    private let chooseFolder: (NSWindow?) async -> URL?
    private var filePanelStorage: FileNameSearchController?
    private var multiPanelStorage: MultiFileSearchController?
    private var monitor: Any?
    private var gesture = DoubleShiftGesture()
    private var activationTask: Task<Void, Never>?
    private var activationGeneration = UUID()
    private var preferences = AppSettings.defaults

    func applyPreferences(_ settings: AppSettings) {
        let visibilityChanged = preferences.showHiddenFiles != settings.showHiddenFiles
        preferences = settings
        browser?.showHiddenFiles = settings.showHiddenFiles
        multiPanelStorage?.applyPreferences(settings)
        if visibilityChanged {
            activationTask?.cancel(); activationGeneration = UUID()
            if filePanelStorage?.window?.isVisible == true { filePanelStorage?.refreshIndex() }
        }
    }


    init(workspace: ScratchWorkspaceUseCase, search: SearchWorkspaceUseCase?, folderSearch: FolderSearchUseCase?,
         folderFileNames: (any FolderFileNameIndexing)? = nil,
         files: FileDocumentUseCase?, browser: WorkspaceBrowserUseCase?, parent: NSWindow?,
         actionable: @escaping () -> Bool, openWorkspace: @escaping (WorkspaceBrowserEntry) -> Void,
         activate: @escaping (MultiFileSearchResults.Row.Target) -> Void,
         onGesture: @escaping () -> Void,
         chooseFolder: @escaping (NSWindow?) async -> URL?) {
        self.workspace = workspace; self.search = search; self.folderSearch = folderSearch; self.files = files
        self.browser = browser; self.folderFileNames = folderFileNames; self.parent = parent; self.actionable = actionable; self.openWorkspace = openWorkspace
        self.activate = activate; self.chooseFolder = chooseFolder; self.onGesture = onGesture
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown]) { [weak self] event in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let parent = self.parent, event.window === parent, parent.isKeyWindow,
                      parent.attachedSheet == nil, self.actionable(),
                      (parent.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else {
                    self.gesture.reset(); return
                }
                if self.gesture.handle(event) { self.onGesture() }
            }
            // Modifier releases still reach the original responder to avoid stuck Shift.
            return event
        }
    }

    var filePanel: FileNameSearchController {
        if let filePanelStorage { return filePanelStorage }
        let panel = FileNameSearchController()
        panel.onSearchRequest = { [weak self] scope, folder, query in
            guard let self, self.actionable() else { throw CancellationError() }
            if scope == .folder {
                guard let folder, let indexer = self.folderFileNames else { throw SearchFailure.invalidLimits }
                let index = try await indexer.search(in: folder, query: query, maximumEntries: 20_000, includeHiddenFiles: self.preferences.showHiddenFiles)
                try Task.checkCancellation()
                guard self.actionable() else { throw CancellationError() }
                let worker = Task.detached(priority: .userInitiated) {
                    index.relativePaths.compactMap { relative -> FileNameSearchEntry? in
                        guard !Task.isCancelled else { return nil }
                        return FileNameSearchEntry(name: URL(fileURLWithPath: relative).lastPathComponent,
                            path: URL(fileURLWithPath: index.rootPath).appendingPathComponent(relative).path,
                            target: .folder(root: folder, authority: index.root, relativePath: relative), project: folder.lastPathComponent)
                    }
                }
                let entries = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
                return (entries, index.isTruncated, index.skippedCount)
            }
            guard scope != .openDocuments, let browser = self.browser else { return ([], false, 0) }
            let originalRoots = browser.roots
            let index = try await browser.fileNameIndex(query: query)
            guard self.actionable(), browser.roots == originalRoots else { throw CancellationError() }
            let roots = Dictionary(uniqueKeysWithValues: browser.roots.map { ($0.id, $0.canonicalPath) })
            let worker = Task.detached(priority: .userInitiated) {
                index.files.compactMap { entry -> FileNameSearchEntry? in
                    guard !Task.isCancelled, let root = roots[entry.rootID] else { return nil }
                    return .init(name: entry.name, path: URL(fileURLWithPath: root).appendingPathComponent(entry.relativePath).path, target: .workspace(entry), project: URL(fileURLWithPath: root).lastPathComponent)
                }
            }
            let entries = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            return (entries, index.isTruncated, index.skippedDirectoryCount)
        }
        panel.onLoadRequest = { [weak panel] scope, folder in
            guard let search = panel?.onSearchRequest else { throw CancellationError() }
            return try await search(scope, folder, "")
        }
        panel.onChooseFolder = { [weak self, weak panel] in await self?.chooseFolder(panel?.window) }
        if prepareFileSplit != nil {
            panel.onOpenInSplit = { [weak self] entry in
                guard let self, self.actionable(), let split = self.prepareFileSplit?() else { return }
                self.openFile(entry, split: split)
            }
        }
        panel.onOpen = { [weak self] entry in self?.openFile(entry, split: nil) }
        filePanelStorage = panel; return panel
    }

    /// Filename opens share one request lifetime, including normal → split and split → normal.
    private func openFile(_ entry: FileNameSearchEntry, split: ((TabID) -> Void)?) {
        guard actionable() else { return }
        activationTask?.cancel(); activationGeneration = UUID()
        let token = activationGeneration
        activationTask = Task { [weak self] in
            guard let self else { return }
            let id: TabID
            switch entry.target {
            case .tab(let target):
                guard self.workspace.snapshot().tabs.contains(where: { $0.id == target }) else { return }
                id = target
            case .folder(let root, let authority, let relative):
                guard let files, let folderFileNames = self.folderFileNames else { return }
                do {
                    let read = try await folderFileNames.readFile(in: root, root: authority, relativePath: relative)
                    guard !Task.isCancelled, self.actionable(), self.activationGeneration == token else { return }
                    if let existing = self.workspace.tabID(canonicalPath: read.url.path) { id = existing }
                    else {
                        let scoped = root.startAccessingSecurityScopedResource()
                        defer { if scoped { root.stopAccessingSecurityScopedResource() } }
                        let outcome = await files.prepareFileForNavigation(read)
                        guard !Task.isCancelled, self.actionable(), self.activationGeneration == token else { return }
                        switch outcome {
                        case .opened(let target), .activatedExisting(let target): id = target
                        case .failed(let failure): self.presentFailure(failure); return
                        }
                    }
                } catch {
                    if !Task.isCancelled, self.activationGeneration == token { self.presentFailure(error) }
                    return
                }
            case .workspace(let file):
                guard let browser = self.browser, let files = self.files else {
                    if split == nil { self.openWorkspace(file) }
                    return
                }
                do {
                    let read = try await browser.readFile(file)
                    guard !Task.isCancelled, self.actionable(), self.activationGeneration == token else { return }
                    if let existing = self.workspace.tabID(canonicalPath: read.url.path) { id = existing; break }
                    let outcome = await files.prepareFolderSearchDocument(.init(path: read.url.path,
                        relativePath: file.relativePath, identity: read.result.identity, matches: []))
                    guard !Task.isCancelled, self.actionable(), self.activationGeneration == token else { return }
                    switch outcome {
                    case .opened(let target), .activatedExisting(let target): id = target
                    case .failed(let failure): self.presentFailure(failure); return
                    }
                } catch {
                    if !Task.isCancelled, self.activationGeneration == token { self.presentFailure(error) }
                    return
                }
            }
            guard !Task.isCancelled, self.actionable(), self.activationGeneration == token else { return }
            if let split { split(id) }
            else {
                _ = await self.workspace.activateIfCurrent(tabID: id, isCurrent: {
                    self.actionable() && self.activationGeneration == token
                })
            }
        }
    }

    func waitForFileOpen() async { await activationTask?.value }

    var multiPanel: MultiFileSearchController {
        if let multiPanelStorage { return multiPanelStorage }
        let panel = MultiFileSearchController()
        panel.applyPreferences(preferences)
        panel.onSearchRequest = { [weak self] query, scope, folder, progress in
            guard let self, self.actionable(), let search = self.search else { throw SearchFailure.cancelled }
            let roots = self.browser?.roots ?? []
            if let folderSearch = self.folderSearch {
                let delivery = SearchProgressDelivery(receive: progress)
                return .combined(try await ProjectSearchUseCase(workspace: self.workspace, search: search, folderSearch: folderSearch)
                    .find(query, scope: scope, roots: roots, folder: folder, onProgress: { delivery.offer(.combined($0)) }))
            }
            guard scope == .openDocuments || scope == .all && roots.isEmpty else { throw SearchFailure.invalidLimits }
            return .open(try await search.findAll(query))
        }
        panel.onReplace = { [weak self] query, result in
            guard let self, self.actionable() else { throw SearchFailure.cancelled }
            return try await self.replace(query, result: result)
        }
        panel.onPreview = { [weak self] target in
            guard let self, self.actionable() else { return nil }
            switch target {
            case .open(let match): return await self.search?.preview(match)
            case .folder(let document, let match): return await self.folderSearch?.preview(document: document, match: match)
            case .document: return nil
            }
        }
        panel.onOpenResults = { [weak self] query, result in
            guard let self, self.actionable() else { return }; self.onOpenResults?(query, result)
        }
        panel.onActivate = { [weak self] target in guard let self, self.actionable() else { return }; self.activate(target) }
        panel.onChooseFolder = { [weak self, weak panel] in await self?.chooseFolder(panel?.window) }
        multiPanelStorage = panel; return panel
    }

    private func replace(_ query: SearchQuery, result: MultiFileSearchResults) async throws -> OpenDocumentsReplacementResult {
        guard !result.isTruncated, let search else { throw SearchFailure.invalidLimits }
        switch result {
        case .open(let preview):
            return try await ProjectDocumentsReplaceUseCase.replaceOpen(query, preview: preview, search: search)
        case .folder(let preview):
            guard let files else { throw SearchFailure.invalidLimits }
            return try await FolderDocumentsReplaceUseCase(workspace: workspace, files: files, search: search).replace(query, preview: preview)
        case .combined(let preview):
            guard let files else { throw SearchFailure.invalidLimits }
            return try await ProjectDocumentsReplaceUseCase(workspace: workspace, files: files, search: search).replace(query, preview: preview)

        }
    }

    func showFiles() {
        guard actionable(), parent?.attachedSheet == nil else { return }
        multiPanelStorage?.dismiss()
        let roots = (browser?.roots ?? []).sorted { $0.canonicalPath.count > $1.canonicalPath.count }
        let initial = workspace.snapshot().tabs.map { tab in
            let root = tab.fullPath.flatMap { path in roots.first { path.hasPrefix($0.canonicalPath + "/") } }
            return FileNameSearchEntry(name: tab.displayTitle, path: tab.fullPath ?? tab.displayTitle, target: .tab(tab.id),
                project: root.map { URL(fileURLWithPath: $0.canonicalPath).lastPathComponent })
        }
        filePanel.configureWorkspace(browser?.roots ?? [])
        filePanel.present(in: parent, initial: initial)
    }
    func showContent(replace: Bool, selectedText: String?) {
        guard actionable(), parent?.attachedSheet == nil else { return }
        filePanelStorage?.dismiss()
        let root = browser?.roots.first(where: \.isAvailable).map { URL(fileURLWithPath: $0.canonicalPath, isDirectory: true) }
        multiPanel.configureWorkspace(browser?.roots ?? [])
        multiPanel.present(replace: replace, in: parent, selectedText: selectedText, defaultFolder: root)
    }
    func dismissActivePanel() -> Bool {
        let visible = filePanelStorage?.window?.isVisible == true || multiPanelStorage?.window?.isVisible == true
        if visible { dismiss() }
        return visible
    }
    func dismiss() { gesture.reset(); filePanelStorage?.dismiss(); multiPanelStorage?.dismiss() }
    func refreshLocalization(catalog: LocalizationCatalog) {
        filePanelStorage?.refreshLocalization(catalog: catalog); multiPanelStorage?.refreshLocalization(catalog: catalog)
    }
    func tearDown() {
        dismiss(); activationTask?.cancel(); activationTask = nil
        if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
    }

    private func presentFailure(_ error: any Error) {
        guard actionable(), let parent else { return }
        let alert = NSAlert()
        alert.messageText = L10n.text("Search Files")
        alert.informativeText = PresentationErrorText.message(error)
        alert.beginSheetModal(for: parent)
    }
}
