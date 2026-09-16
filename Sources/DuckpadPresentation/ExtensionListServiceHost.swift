import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

/// One shared host per application: opening a second editor window does not create
/// a second clipboard observer or a competing copy of plugin state.
@MainActor
public final class ExtensionListServiceHost {
    private let nativeHost: NativePluginServiceHost
    private let storage: any ExtensionServiceStorage
    private let pasteboard: NSPasteboard
    private var changeCount: Int
    private var lastExpirationCheck = Date.distantPast
    private var timer: Task<Void, Never>?
    private final class Owner {
        weak var value: (any ExtensionServiceInvoking)?
        init(_ value: any ExtensionServiceInvoking) { self.value = value }
    }
    private var owners: [ObjectIdentifier: Owner] = [:]
    private var policyGeneration: UInt64 = 0
    private var allowed: [ExtensionCommandID: ExtensionServiceRegistration] = [:]
    private var presentationGeneration: UInt64 = 0
    private var sessions: [ExtensionCommandID: ExtensionListSession] = [:]
    let panel = ExtensionListPanel()
    private var displayedCommand: ExtensionCommandID?
    private var restoreEditorFocus: (() -> Void)?
    private var preparePaste: (() -> ((String) -> Bool)?)?
    public init(storage: any ExtensionServiceStorage, pasteboard: NSPasteboard = .general, nativeStorageRoot: URL? = nil, nativePackageRoot: URL? = nil, prepareNativePackage: (@Sendable ([String: Data]) async throws -> Void)? = nil) {
        nativeHost = NativePluginServiceHost(storageRoot: nativeStorageRoot ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Duckpad/PluginData"), packageRoot: nativePackageRoot, preparePackage: prepareNativePackage)
        self.storage = storage; self.pasteboard = pasteboard; self.changeCount = pasteboard.changeCount
        panel.onClose = { [weak self] in self?.dismissPresentation() }
        panel.onEvent = { [weak self] event, payload, query in self?.send(event, payload: payload, query: query) }
    }
    deinit { timer?.cancel() }

    public func synchronize(_ useCase: any ExtensionServiceInvoking) {
        owners[ObjectIdentifier(useCase)] = Owner(useCase)
        if useCase.servicePolicyGeneration >= policyGeneration {
            policyGeneration = useCase.servicePolicyGeneration
            allowed = Dictionary(uniqueKeysWithValues: useCase.serviceCommands().map { ($0.command.id, $0) })
        }
        reconcile()
    }

    public func unregister(_ useCase: any ExtensionServiceInvoking) {
        owners.removeValue(forKey: ObjectIdentifier(useCase))
        reconcile()
    }

    private func reconcile() {
        owners = owners.filter { $0.value.value != nil }
        var available: [ExtensionCommandID: (ExtensionServiceRegistration, any ExtensionServiceInvoking)] = [:]
        for owner in owners.values {
            guard let useCase = owner.value else { continue }
            for registration in useCase.serviceCommands() where allowed[registration.command.id] == registration {
                available[registration.command.id] = (registration, useCase)
            }
        }
        nativeHost.synchronize(available.values.map { $0.0 }.filter { $0.nativeFiles != nil })
        available = available.filter { $0.value.0.nativeFiles == nil }
        for (id, session) in sessions where available[id]?.0 != session.identity {
            session.invalidate(); sessions.removeValue(forKey: id)
            if displayedCommand == id { dismissPresentation(); panel.close() }
        }
        for (id, entry) in available {
            let (registration, useCase) = entry
            if let existing = sessions[id] { existing.useCase = useCase }
            else {
                let session = ExtensionListSession(identity: registration, useCase: useCase, storage: storage)
                session.onUpdate = { [weak self, weak session] rows, retentionDays, error in
                    guard let self, self.displayedCommand == id, self.sessions[id] === session else { return }
                    self.panel.render(rows, retentionDays: retentionDays, error: error)
                }
                sessions[id] = session
            }
        }
        if !sessions.values.contains(where: { $0.identity.capabilities.contains(.clipboardRead) }) { timer?.cancel(); timer = nil }
        else if timer == nil {
            changeCount = pasteboard.changeCount
            timer = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    guard self != nil else { return }
                    self?.pollClipboard()
                }
            }
        }
    }

    public func show(_ command: ExtensionCommandID, in split: NSSplitView, onClose: @escaping () -> Void = {}, onError: ((Error) -> Void)? = nil, preparePaste: @escaping () -> ((String) -> Bool)?) {
        if nativeHost.contains(command) {
            panel.close()
            presentationGeneration &+= 1
            let generation = presentationGeneration
            Task { @MainActor [weak self, weak split] in
                guard let self, let split else { return }
                do {
                    if let registration = self.allowed[command] { try await self.nativeHost.prepareInstallation(for: registration.extensionID) }
                    guard self.presentationGeneration == generation, split.window != nil else { return }
                    try self.nativeHost.show(command, in: split, onClose: onClose, preparePaste: preparePaste)
                } catch { onError?(error) }
            }
            return
        }
        nativeHost.close()
        guard let session = sessions[command] else { return }
        presentationGeneration &+= 1
        displayedCommand = command; self.preparePaste = preparePaste; restoreEditorFocus = onClose
        panel.show(title: session.identity.command.title, in: split)
        session.send("query", query: panel.query)
    }

    public func prepareNativeInstallation(for extensionID: ExtensionID) async throws {
        try await nativeHost.prepareInstallation(for: extensionID)
    }

    public func refreshLocalization(catalog: LocalizationCatalog) { panel.refreshLocalization(catalog: catalog); nativeHost.refreshLocalization(catalog.language.rawValue) }

    public func close(in split: NSSplitView) {
        presentationGeneration &+= 1
        nativeHost.close(in: split)
        if panel.superview === split { panel.close() }
    }

    func pollClipboard() {
        reconcile()
        let readers = sessions.values.filter { $0.useCase != nil && $0.identity.capabilities.contains(.clipboardRead) }
        guard !readers.isEmpty else { return }
        if Date().timeIntervalSince(lastExpirationCheck) >= 60 {
            lastExpirationCheck = Date()
            for session in readers { session.send("query", query: displayedCommand == session.identity.command.id ? panel.query : "") }
        }
        guard pasteboard.changeCount != changeCount else { return }
        changeCount = pasteboard.changeCount
        let excluded = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType", "org.nspasteboard.AutoGeneratedType"]
        guard !excluded.contains(where: { pasteboard.types?.contains(NSPasteboard.PasteboardType($0)) == true }),
              let text = pasteboard.string(forType: .string), !text.isEmpty else { return }
        for session in readers {
            session.send("capture", payload: text, query: displayedCommand == session.identity.command.id ? panel.query : "")
        }
    }

    private func dismissPresentation() {
        let restore = restoreEditorFocus
        presentationGeneration &+= 1; displayedCommand = nil; preparePaste = nil; restoreEditorFocus = nil
        restore?()
    }

    private func send(_ event: String, payload: String, query: String) {
        guard let command = displayedCommand, let session = sessions[command] else { return }
        let generation = presentationGeneration
        let isPaste = event == "select" || event == "select-next"
        let pasteAction = isPaste ? preparePaste?() : nil
        if isPaste && pasteAction == nil { panel.finishPaste(id: payload, query: query, advance: false, succeeded: false); return }
        session.send(isPaste ? "select" : event, payload: payload, query: query) { [weak self, weak session] text in
            guard let self, let session, self.sessions[command] === session,
                  self.presentationGeneration == generation, self.displayedCommand == command else { return }
            if event == "preview" {
                self.panel.renderPreview(text, id: payload, query: query)
                return
            }
            guard isPaste, session.identity.capabilities.contains(.clipboardWrite) else { return }
            let succeeded = !text.isEmpty && pasteAction?(text) == true
            if succeeded { self.changeCount = self.pasteboard.changeCount }
            self.panel.finishPaste(id: payload, query: query, advance: event == "select-next", succeeded: succeeded)
        }
    }
}
