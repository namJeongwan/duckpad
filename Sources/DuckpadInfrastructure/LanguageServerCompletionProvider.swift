import Foundation
import DuckpadApplication
import DuckpadDomain
import LanguageClient
import LanguageServerProtocol
import JSONRPC

@MainActor public final class LanguageServerCompletionProvider: DocumentCompletionProviding {
    @MainActor private final class Session {
        let transport: LanguageServerTransport
        let server: InitializingServer
        let root: URL
        let serverID: String
        let context: LanguageServerLaunchContext
        var documents: [String: (version: Int, bytes: Data)] = [:]
        var pending: Task<[DocumentCompletionSuggestion], any Error>?
        var events: Task<Void, Never>?
        init(transport: LanguageServerTransport, server: InitializingServer, root: URL, serverID: String, context: LanguageServerLaunchContext) {
            self.transport = transport; self.server = server; self.root = root; self.serverID = serverID; self.context = context
        }
    }
    private struct RootKey: Hashable {
        let workspaceID: SessionID
        let folderID: String?
        let service: String
        let document: String
    }
    private struct SessionKey: Hashable {
        let workspaceID: SessionID
        let folderID: String
        let service: String
        let digest: String
        let server: String
        let project: String
    }
    private let documentURL: @MainActor (BufferID) -> URL?
    private let workspaceIdentity: @MainActor () -> SessionID
    public var currentWorkspaceID: SessionID { workspaceIdentity() }
    public private(set) var workspaceFolders: [LanguageServiceFolder] = []
    public var onInvalidation: (@MainActor () -> Void)?
    public var validateRegistration: (@MainActor (LanguageServerRegistration) async -> Bool)?
    private var registry: LanguageServerAdapterRegistry
    private var settings: [String: LanguageServiceSettings]
    private var configuredWorkspaceID: SessionID
    private var projectedSettings: [String: LanguageServiceSettings]
    private var generation = 0
    public private(set) var failedServices: Set<String> = []
    private var documentRoots: [RootKey: URL] = [:]
    private var rootRequests: [RootKey: Task<URL?, Never>] = [:]
    private var sessions: [SessionKey: Session] = [:]
    private var launches: [SessionKey: Task<Session, any Error>] = [:]
    private var launchingTransports: [UUID: LanguageServerTransport] = [:]
    private var retryAfter: [SessionKey: Date] = [:]
    private struct Resolution {
        let session: Session
        let raw: CompletionItem
        let capture: DocumentIntelligenceCapture
        var resolved: DocumentCompletionSuggestion?
    }
    private var resolutions: [UUID: Resolution] = [:]
    private var openBuffers: [BufferID: (key: SessionKey, uri: String)] = [:]
    public init(registry: LanguageServerAdapterRegistry = .empty, settings: [String: LanguageServiceSettings] = [:],
                workspaceID: (@MainActor () -> SessionID)? = nil,
                documentURL: @escaping @MainActor (BufferID) -> URL?) {
        let fallback = SessionID()
        let identity: @MainActor () -> SessionID = workspaceID ?? { fallback }
        let id = identity()
        self.workspaceIdentity = identity; self.configuredWorkspaceID = id
        self.registry = registry; self.documentURL = documentURL; self.settings = settings
        self.projectedSettings = Self.project(settings, registry: registry, workspaceID: id)
    }
    private static func project(_ values: [String: LanguageServiceSettings], registry: LanguageServerAdapterRegistry,
                                workspaceID: SessionID) -> [String: LanguageServiceSettings] {
        Dictionary(uniqueKeysWithValues: registry.registrations.map {
            ($0.settingsKey, (values[$0.settingsKey] ?? .init()).isolated(to: workspaceID))
        })
    }
    public func workspaceFolder(for document: URL) -> LanguageServiceFolder? {
        workspaceFolders.filter { $0.contains(document.path) }.max { $0.path.count < $1.path.count }
    }
    @discardableResult public func updateWorkspaceFolders(_ values: [LanguageServiceFolder]) -> Bool {
        let next = values.filter(\.isValid).sorted { $0.id < $1.id }
        let changed = next.count != workspaceFolders.count || zip(next, workspaceFolders).contains { pair in pair.0.id != pair.1.id || pair.0.path != pair.1.path }
        workspaceFolders = next
        guard changed else { return false }
        shutdown(); onInvalidation?()
        return true
    }

    public func completions(in capture: DocumentIntelligenceCapture, prefixRange: SearchUTF8Range) async throws -> [DocumentCompletionSuggestion] {
        guard capture.utf8.count <= 1_048_576,
              let registration = registry.registration(forLanguageID: capture.languageID.rawValue),
              let url = documentURL(capture.buffer.bufferID), url.isFileURL else { return [] }
        let workspaceID = currentWorkspaceID
        if configuredWorkspaceID != workspaceID { update(registrations: registry.registrations, settings: settings) }
        let selectedFolder = workspaceFolder(for: url)
        let launchGeneration = generation
        guard await validateRegistration?(registration) ?? true, launchGeneration == generation, currentWorkspaceID == workspaceID else { return [] }
        let rootKey = RootKey(workspaceID: workspaceID, folderID: selectedFolder?.id, service: registration.settingsKey, document: url.path)
        let root: URL
        if let existing = documentRoots[rootKey] { root = existing }
        else {
            let task = rootRequests[rootKey] ?? Task { await LanguageServerProjectRootResolver.resolve(url, registration: registration) }
            rootRequests[rootKey] = task
            let resolved = await task.value
            guard launchGeneration == generation else { return [] }
            rootRequests[rootKey] = nil
            guard let resolved, !Task.isCancelled else { return [] }
            if documentRoots.count >= 256 { documentRoots.removeAll() }
            documentRoots[rootKey] = resolved; root = resolved
        }
        guard currentWorkspaceID == workspaceID, workspaceFolder(for: url) == selectedFolder else { return [] }
        let folder = selectedFolder ?? .project(root.path)
        let serviceSettings = (settings[registration.settingsKey] ?? .init()).isolated(to: workspaceID)
        let selected = serviceSettings.server(forProject: root.path, workspaceID: workspaceID, folder: folder, default: registration.service.defaultServerID)
        guard selected != "disabled", registration.service.servers.contains(where: { $0.id == selected }) else { return [] }
        let request = LanguageServerLaunchRequest(registration: registration, documentPath: url.path,
            serverID: selected, settings: serviceSettings, workspaceID: workspaceID, folder: folder)
        guard request.isValid else { return [] }
        var key = SessionKey(workspaceID: workspaceID, folderID: folder.id, service: registration.settingsKey, digest: registration.packageDigest, server: selected, project: root.path)
        if let old = openBuffers[capture.buffer.bufferID], old.key != key || old.uri != url.absoluteString { retire(bufferID: capture.buffer.bufferID) }
        guard retryAfter[key, default: .distantPast] < Date() else { return [] }
        do {
            let session: Session
            if let existing = sessions[key] { session = existing }
            else {
                let launch = launches[key] ?? Task { try await self.launch(request) }
                launches[key] = launch
                let launched = try await launch.value
                guard launchGeneration == generation else {
                    launched.events?.cancel(); launched.transport.stop(); throw CancellationError()
                }
                launches[key] = nil
                documentRoots[rootKey] = launched.root
                key = SessionKey(workspaceID: workspaceID, folderID: folder.id, service: registration.settingsKey, digest: registration.packageDigest, server: launched.serverID, project: launched.root.path)
                if let existing = sessions[key], existing !== launched {
                    launched.events?.cancel(); launched.transport.stop(); session = existing
                } else { session = launched }
                if sessions[key] == nil, sessions.count >= 4, let retiredKey = sessions.keys.first,
                   let retired = sessions.removeValue(forKey: retiredKey) {
                    retired.pending?.cancel(); retired.events?.cancel(); retired.transport.stop()
                    openBuffers = openBuffers.filter { $0.value.key != retiredKey }
                    resolutions = resolutions.filter { $0.value.session !== retired }
                }
                sessions[key] = session
                failedServices.remove(registration.settingsKey)
            }
            try Task.checkCancellation()
            openBuffers[capture.buffer.bufferID] = (key, url.absoluteString)
            let previous = session.pending
            previous?.cancel()
            let task = Task { @MainActor in
                _ = await previous?.result
                try Task.checkCancellation()
                return try await self.request(session, capture: capture, uri: url.absoluteString, prefixRange: prefixRange)
            }
            session.pending = task
            let result = try await task.value
            guard launchGeneration == generation, currentWorkspaceID == workspaceID, workspaceFolder(for: url) == selectedFolder, await validateRegistration?(registration) ?? true else { return [] }
            return result
        } catch is CancellationError { return [] }
        catch is AnyJSONRPCResponseError { return [] }
        catch {
            guard launchGeneration == generation else { return [] }
            failedServices.insert(registration.settingsKey)
            sessions.removeValue(forKey: key)?.transport.stop()
            launches[key] = nil; retryAfter[key] = Date().addingTimeInterval(10)
            return []
        }
    }

    private func launch(_ request: LanguageServerLaunchRequest) async throws -> Session {
        let transport = LanguageServerTransport()
        let launchID = UUID(); launchingTransports[launchID] = transport
        var launched = false
        defer {
            launchingTransports.removeValue(forKey: launchID)
            if !launched { transport.stop() }
        }
        let (channel, context) = try await transport.start(request)
        try Task.checkCancellation()
        let root = context.root
        guard let definition = request.registration.definition(serverID: context.serverID),
              let serverDefinition = request.registration.service.servers.first(where: { $0.id == context.serverID }) else { throw CocoaError(.executableLoad) }
        let adapter = PluginLanguageServerAdapter(definition: definition, server: serverDefinition, interpreterPath: context.interpreterPath)
        let raw = JSONRPCServerConnection(dataChannel: channel)
        let server = InitializingServer(server: raw) {
            let completion = CompletionClientCapabilities(completionItem: .init(snippetSupport: false,
                documentationFormat: [.plaintext, .markdown], deprecatedSupport: true,
                insertReplaceSupport: true, resolveSupport: .init(properties: ["documentation", "detail", "additionalTextEdits"]),
                labelDetailsSupport: true), contextSupport: true)
            let workspace = ClientCapabilities.Workspace(applyEdit: false, workspaceEdit: nil,
                didChangeConfiguration: nil, didChangeWatchedFiles: nil, symbol: nil, executeCommand: nil,
                workspaceFolders: true, configuration: true, semanticTokens: nil)
            let capabilities = ClientCapabilities(workspace: workspace,
                textDocument: .init(completion: completion), window: nil, general: nil, experimental: nil)
            return InitializeParams(processId: Int(ProcessInfo.processInfo.processIdentifier), clientInfo: .init(name: "Duckpad"),
                locale: nil, rootPath: root.path, rootUri: root.absoluteString,
                initializationOptions: adapter.initializationOptions(projectRoot: root),
                capabilities: capabilities, trace: .off, workspaceFolders: [.init(uri: root.absoluteString, name: root.lastPathComponent)])
        }
        let session = Session(transport: transport, server: server, root: root, serverID: context.serverID, context: context)
        // Reply to standard server-to-client requests; dynamic registrations are
        // handled by LanguageClient's InitializingServer wrapper.
        session.events = Task {
            for await event in server.eventSequence {
                guard case .request(_, let request) = event else { continue }
                switch request {
                case .workspaceConfiguration(let params, let reply):
                    await reply(.success(params.items.map { adapter.configuration(section: $0.section, scopeURI: $0.scopeUri, projectRoot: root) ?? .null }))
                case .workspaceFolders(let reply): await reply(.success([.init(uri: root.absoluteString, name: root.lastPathComponent)]))
                case .windowWorkDoneProgressCreate(_, let reply): await reply(nil)
                case .workspaceApplyEdit(_, let reply): await reply(.success(.init(applied: false)))
                case .windowShowMessageRequest(_, let reply): await reply(.success(nil))
                case .windowShowDocument(_, let reply): await reply(.success(.init(success: false)))
                case .workspaceCodeLensRefresh(let reply), .workspaceSemanticTokenRefresh(let reply): await reply(nil)
                case .custom(_, _, let reply): await reply(.success(.null))
                default: break
                }
            }
        }
        let timeout = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            transport.stop()
        }
        do {
            _ = try await server.initializeIfNeeded()
            if let settings = adapter.configuration(section: nil, scopeURI: nil, projectRoot: root) {
                try await server.didChangeConfiguration(.init(settings: settings))
            }
            timeout.cancel(); launched = true; return session
        }
        catch { timeout.cancel(); transport.stop(); session.events?.cancel(); throw error }
    }

    private func request(_ session: Session, capture: DocumentIntelligenceCapture, uri: String,
                         prefixRange: SearchUTF8Range) async throws -> [DocumentCompletionSuggestion] {
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }; session.transport.stop()
        }
        defer { timer.cancel() }
        let coordinates = LSPTextCoordinates(capture.utf8)
        guard let position = coordinates.position(capture.caretUTF8),
              let text = String(data: capture.utf8, encoding: .utf8) else { return [] }
        let old = session.documents[uri]
        let version = (old?.version ?? 0) + 1
        if old == nil {
            if session.documents.count >= 32, let retired = session.documents.keys.first {
                try await session.server.textDocumentDidClose(.init(textDocument: .init(uri: retired)))
                session.documents.removeValue(forKey: retired)
            }
            try await session.server.textDocumentDidOpen(.init(textDocument: .init(uri: uri,
                languageId: capture.languageID.rawValue, version: version, text: text)))
        } else if old!.bytes != capture.utf8 {
            let mode = await session.server.capabilities?.textDocumentSync
            let incremental: Bool
            switch mode {
            case .optionA(let options): incremental = options.change == .incremental
            case .optionB(let kind): incremental = kind == .incremental
            default: incremental = false
            }
            let end = LSPTextCoordinates(old!.bytes).position(old!.bytes.count)
            let range = incremental ? end.map { LSPRange(start: .init(line: 0, character: 0), end: $0) } : nil
            try await session.server.textDocumentDidChange(.init(uri: uri, version: version,
                contentChange: .init(range: range, rangeLength: nil, text: text)))
        }
        session.documents[uri] = (version, capture.utf8)
        let response = try await session.server.completion(.init(uri: uri, position: position, triggerKind: .invoked, triggerCharacter: nil))
        try Task.checkCancellation()
        let items: [CompletionItem]
        switch response {
        case .optionA(let array): items = array
        case .optionB(let list): items = list.items
        case nil: return []
        }
        if resolutions.count > 2_000 { resolutions.removeAll() }
        return items.prefix(2_000).compactMap { item in
            guard var suggestion = Self.suggestion(item, coordinates: coordinates, caret: capture.caretUTF8, prefixRange: prefixRange) else { return nil }
            let id = UUID(); suggestion.resolutionID = id
            resolutions[id] = .init(session: session, raw: item, capture: capture)
            return suggestion
        }
    }

    public func resolve(_ suggestion: DocumentCompletionSuggestion, capture: DocumentIntelligenceCapture) async -> DocumentCompletionSuggestion? {
        guard let id = suggestion.resolutionID else { return suggestion }
        guard let resolution = resolutions[id], resolution.session.context.workspaceID == currentWorkspaceID else { return nil }
        guard resolution.capture.buffer == capture.buffer, resolution.capture.caretUTF8 == capture.caretUTF8 else { return nil }
        guard let registration = registry.registrations.first(where: { $0.settingsKey == resolution.session.context.settingsKey }),
              await validateRegistration?(registration) ?? true, resolution.session.context.workspaceID == currentWorkspaceID, resolutions[id] != nil else { return nil }
        if let resolved = resolution.resolved { return resolved }
        let supportsResolve = await resolution.session.server.capabilities?.completionProvider?.resolveProvider == true
        guard resolution.session.context.workspaceID == currentWorkspaceID, resolutions[id] != nil else { return nil }
        guard supportsResolve else { return suggestion }
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }; resolution.session.transport.stop()
        }
        defer { timer.cancel() }
        do {
            let raw = try await resolution.session.server.completeItemResolve(resolution.raw)
            guard var resolved = Self.suggestion(raw, coordinates: LSPTextCoordinates(capture.utf8),
                caret: capture.caretUTF8, prefixRange: suggestion.insertRange) else { return nil }
            resolved.resolutionID = id; resolved.matches = suggestion.matches
            resolutions[id]?.resolved = resolved
            guard await validateRegistration?(registration) ?? true, resolution.session.context.workspaceID == currentWorkspaceID, resolutions[id] != nil else { return nil }
            return resolved
        } catch { return nil }
    }

    static func suggestion(_ item: CompletionItem, coordinates: LSPTextCoordinates, caret: Int,
                           prefixRange: SearchUTF8Range) -> DocumentCompletionSuggestion? {
        guard !item.label.isEmpty, item.label.utf8.count <= 1_024, !item.label.contains("\n"), item.insertTextFormat != .snippet else { return nil }
        var insert = prefixRange, replace = prefixRange, text = item.insertText ?? item.label
        switch item.textEdit {
        case .optionA(let edit):
            guard let range = coordinates.range(edit.range) else { return nil }; insert = range; replace = range; text = edit.newText
        case .optionB(let edit):
            guard let a = coordinates.range(edit.insert), let b = coordinates.range(edit.replace) else { return nil }
            insert = a; replace = b; text = edit.newText
        case nil: break
        }
        guard insert.location <= caret, insert.location + insert.length >= caret,
              replace.location <= caret, replace.location + replace.length >= caret,
              text.utf8.count <= 65_536, (item.additionalTextEdits?.count ?? 0) <= 64 else { return nil }
        var additional: [SearchReplacementEdit] = []
        for edit in item.additionalTextEdits ?? [] {
            guard let range = coordinates.range(edit.range), edit.newText.utf8.count <= 65_536 else { return nil }
            additional.append(.init(range: range, replacementUTF8: Data(edit.newText.utf8)))
        }
        let documentation: String
        switch item.documentation { case .optionA(let text): documentation = text; case .optionB(let markup): documentation = markup.value; case nil: documentation = "" }
        let labelDetail = [item.labelDetails?.detail, item.labelDetails?.description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        let detail = item.detail.flatMap { $0.isEmpty ? nil : $0 } ?? labelDetail
        return .init(label: item.label, detail: String(detail.prefix(512)),
            documentation: String(documentation.prefix(4_096)), kind: item.kind?.rawValue ?? 1, source: .languageServer,
            filterText: item.filterText, sortText: item.sortText, insertText: text, insertRange: insert,
            replaceRange: replace, additionalEdits: additional)
    }
    @discardableResult public func update(registrations: [LanguageServerRegistration], settings: [String: LanguageServiceSettings]) -> Bool {
        let next = LanguageServerAdapterRegistry(registrations: registrations)
        let workspaceID = currentWorkspaceID
        let projection = Self.project(settings, registry: next, workspaceID: workspaceID)
        let retry = !failedServices.isEmpty && self.settings == settings
        self.settings = settings
        guard registry != next || projectedSettings != projection || configuredWorkspaceID != workspaceID || retry else { return false }
        shutdown()
        registry = next; projectedSettings = projection; configuredWorkspaceID = workspaceID
        onInvalidation?()
        return true
    }
    public var conflictingLanguages: Set<String> { registry.conflictingLanguages }
    public var registrations: [LanguageServerRegistration] { registry.registrations }
    public func context(for document: URL, languageID: String? = nil) -> LanguageServerLaunchContext? {
        sessions.values.filter { session in
            session.context.workspaceID == currentWorkspaceID
                && session.context.folderID == (workspaceFolder(for: document)?.id ?? LanguageServiceFolder.project(session.root.path).id)
                && (languageID == nil || registry.registrations.contains { $0.settingsKey == session.context.settingsKey && $0.service.languageID == languageID })
                && document.path.hasPrefix(session.root.path + "/")
        }.max { $0.root.path.count < $1.root.path.count }?.context
    }

    public func shutdown() {
        generation += 1
        documentRoots.removeAll()
        for request in rootRequests.values { request.cancel() }; rootRequests.removeAll()
        retryAfter.removeAll()
        failedServices.removeAll()
        openBuffers.removeAll()
        resolutions.removeAll()
        for transport in launchingTransports.values { transport.stop() }; launchingTransports.removeAll()
        for session in sessions.values { session.pending?.cancel(); session.events?.cancel(); session.transport.stop() }
        sessions.removeAll()
        for launch in launches.values { launch.cancel() }; launches.removeAll()
    }

    public func retire(bufferID: BufferID) {
        resolutions = resolutions.filter { $0.value.capture.buffer.bufferID != bufferID }
        guard let document = openBuffers.removeValue(forKey: bufferID), let session = sessions[document.key] else { return }
        let previous = session.pending; previous?.cancel()
        session.pending = Task { @MainActor in
            _ = await previous?.result
            if session.documents.removeValue(forKey: document.uri) != nil {
                try? await session.server.textDocumentDidClose(.init(textDocument: .init(uri: document.uri)))
            }
            return []
        }
    }
}
