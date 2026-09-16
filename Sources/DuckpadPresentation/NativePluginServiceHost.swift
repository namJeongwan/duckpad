import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

/// Generic native panel hosting. No clipboard-specific controls or data live here.
@MainActor final class NativePluginServiceHost {
    private let storageRoot: URL
    private let cacheRoot: URL
    private let verifier: any NativePluginInstallationVerifying
    private var activationIDs: [ExtensionCommandID: UUID] = [:]
    private let preparePackage: (@Sendable ([String: Data]) async throws -> Void)?
    private var installations: [ExtensionCommandID: Task<Void, Error>] = [:]
    private var instances: [ExtensionCommandID: NativePluginInstance] = [:]
    private var registrations: [ExtensionCommandID: ExtensionServiceRegistration] = [:]
    private var failures: [ExtensionCommandID: Error] = [:]
    private var displayed: ExtensionCommandID?
    private var panel: NSView?
    private weak var window: NSWindow?
    private var previousMinimum: NSSize?
    private var editorMinimum: NSLayoutConstraint?
    private var restoreFocus: (() -> Void)?
    private var language = L10n.catalog.language.rawValue
    init(storageRoot: URL, packageRoot: URL? = nil, verifier: any NativePluginInstallationVerifying, preparePackage: (@Sendable ([String: Data]) async throws -> Void)? = nil) {
        self.storageRoot = storageRoot
        self.verifier = verifier
        cacheRoot = packageRoot ?? storageRoot.deletingLastPathComponent().appendingPathComponent("NativePluginModules")
        self.preparePackage = preparePackage
    }
    func synchronize(_ registrations: [ExtensionServiceRegistration]) {
        let allowed = Dictionary(uniqueKeysWithValues: registrations.map { ($0.command.id, $0) })
        let previous = self.registrations
        self.registrations = allowed
        for (id, task) in installations where allowed[id] == nil || allowed[id] != previous[id] { task.cancel(); installations.removeValue(forKey: id); activationIDs.removeValue(forKey: id) }
        for (id, entry) in instances where allowed[id] != entry.registration {
            if displayed == id { close() }
            entry.stop(); instances.removeValue(forKey: id)
        }
        failures = failures.filter { allowed[$0.key] != nil && allowed[$0.key] == previous[$0.key] }
        for registration in registrations where instances[registration.command.id] == nil {
            if installations[registration.command.id] == nil {
                beginInstallation(registration)
            }
        }
    }
    private func beginInstallation(_ registration: ExtensionServiceRegistration) {
        let id = registration.command.id
        let token = UUID()
        activationIDs[id] = token
        let verifier = verifier
        let cacheRoot = cacheRoot
        let preparePackage = preparePackage
        installations[id] = Task { @MainActor [weak self] in
            do {
                let installation: any VerifiedNativePluginInstallation
                do {
                    installation = try await verifier.open(registration, root: cacheRoot)
                } catch NativePluginValidationFailure.installationRequired {
                    guard let files = registration.nativeFiles, let preparePackage else { throw NativePluginValidationFailure.installationRequired }
                    try Task.checkCancellation()
                    try await preparePackage(files)
                    try Task.checkCancellation()
                    installation = try await verifier.open(registration, root: cacheRoot)
                }
                try Task.checkCancellation()
                guard let self, self.activationIDs[id] == token, self.registrations[id] == registration else { throw CancellationError() }
                if self.instances[id] == nil {
                    self.instances[id] = try NativePluginInstance(registration, root: self.storageRoot, installation: installation, language: self.language)
                }
                self.failures.removeValue(forKey: id)
                self.installations.removeValue(forKey: id)
                self.activationIDs.removeValue(forKey: id)
            } catch {
                if let self, self.activationIDs[id] == token {
                    if !Task.isCancelled { self.failures[id] = error }
                    self.installations.removeValue(forKey: id)
                    self.activationIDs.removeValue(forKey: id)
                }
                throw error
            }
        }
    }
    func prepareInstallation(for extensionID: ExtensionID) async throws {
        let commands = registrations.values.filter { $0.extensionID == extensionID }.map { $0.command.id }.sorted()
        for command in commands { try await prepareInstallation(command: command) }
    }
    func prepareInstallation(command id: ExtensionCommandID) async throws {
        guard instances[id] == nil else { return }
        guard let registration = registrations[id] else { throw CancellationError() }
        if installations[id] == nil { beginInstallation(registration) }
        if let task = installations[id] { try await task.value }
    }
    func contains(_ id: ExtensionCommandID) -> Bool { registrations[id] != nil }
    func show(_ id: ExtensionCommandID, in split: NSSplitView, onClose: @escaping () -> Void, preparePaste: @escaping () -> ((String) -> Bool)?) throws {
        if let failure = failures[id] { throw failure }
        guard let entry = instances[id] else { throw CocoaError(.executableNotLoadable) }
        close()
        let view = try entry.makeView()
        displayed = id; panel = view; window = split.window; restoreFocus = onClose
        entry.preparePaste = preparePaste; entry.onClose = { [weak self] in self?.close() }
        if let window {
            previousMinimum = window.minSize
            window.minSize.width = max(420, window.minSize.width) + 340
            if window.frame.width < window.minSize.width {
                var frame = window.frame; frame.size.width = window.minSize.width
                window.setFrame(frame, display: true)
            }
        }
        if let editor = split.arrangedSubviews.last {
            editorMinimum = editor.widthAnchor.constraint(greaterThanOrEqualToConstant: 120)
            editorMinimum?.isActive = true
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.frame = NSRect(x: 0, y: 0, width: 340, height: split.bounds.height)
        split.addArrangedSubview(view)
        split.setHoldingPriority(.init(260), forSubviewAt: split.arrangedSubviews.count - 1)
        split.adjustSubviews()
        split.setPosition(max(0, split.bounds.width - 340 - split.dividerThickness), ofDividerAt: split.arrangedSubviews.count - 2)
        window?.makeFirstResponder(view)
    }
    func close(in split: NSSplitView) { if panel?.superview === split { close() } }
    func closeFocusedPanel(in split: NSSplitView) -> Bool {
        guard let panel, PluginPanelFocus.ownsKeyboardFocus(panel, in: split) else { return false }
        close()
        return true
    }
    func close() {
        if let displayed { instances[displayed]?.detach() }
        if let panel {
            (panel.superview as? NSSplitView)?.removeArrangedSubview(panel)
            panel.removeFromSuperview()
        }
        if let previousMinimum { window?.minSize = previousMinimum }
        editorMinimum?.isActive = false; editorMinimum = nil
        previousMinimum = nil; window = nil; panel = nil; displayed = nil
        let restore = restoreFocus; restoreFocus = nil; restore?()
    }
    func refreshLocalization(_ language: String) {
        self.language = language
        for instance in instances.values { instance.setLanguage(language) }
    }
}
