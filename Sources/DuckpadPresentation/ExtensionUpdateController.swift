import AppKit
import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization

@MainActor final class ExtensionUpdateController {
    typealias Check = @Sendable ([ExtensionRegistryItem]) async throws -> [ExtensionID: ExtensionUpdate]
    typealias Prepare = @Sendable (ExtensionUpdate, String) async throws -> PreparedExtensionUpdate
    typealias Install = @Sendable (PreparedExtensionUpdate) async throws -> Void
    typealias Browse = @Sendable () async throws -> ExtensionCatalogSnapshot
    private let browse: Browse
    private let activate: (ExtensionID) async throws -> Void
    private var catalogPlugins: [ExtensionCatalogPlugin] = []
    private var catalogTask: Task<Void, Never>?
    private var catalogStatusKey = ""
    private var hasLoadedCatalog = false
    typealias Uninstall = @Sendable (ExtensionRegistryItem) async throws -> Void
    private let uninstall: Uninstall
    private var activeInstallID: ExtensionID?
    private var removing = false
    private let useCase: ExtensionWorkspaceUseCase
    private let panel: ExtensionsManagerPanel
    private let check: Check
    private let prepare: Prepare
    private let install: Install
    private let onError: (Error) -> Void
    private var updates: [ExtensionID: ExtensionUpdate] = [:]
    private var lastCheck = Date.distantPast
    private var checkTask: Task<Void, Never>?
    private var installTask: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var statusKey = ""
    private var checkGeneration = UUID()

    init(useCase: ExtensionWorkspaceUseCase, panel: ExtensionsManagerPanel, check: @escaping Check,
         prepare: @escaping Prepare, install: @escaping Install, browse: @escaping Browse = { .init(plugins: []) }, activate: @escaping (ExtensionID) async throws -> Void = { _ in }, uninstall: @escaping Uninstall = { _ in throw ExtensionFailure.hostUnavailable("uninstall unavailable") }, onError: @escaping (Error) -> Void) {
        self.uninstall = uninstall
        self.browse = browse; self.activate = activate
        self.useCase = useCase; self.panel = panel; self.check = check; self.prepare = prepare; self.install = install; self.onError = onError
        panel.onUninstall = { [weak self] item in self?.remove(item) }
        panel.onBrowse = { [weak self] in self?.loadCatalog() }
        panel.catalogView.onReload = { [weak self] in self?.loadCatalog(force: true) }
        panel.catalogView.onInstall = { [weak self] in self?.installFromCatalog($0) }
        panel.onCheckUpdates = { [weak self] in self?.checkNow() }
        panel.onUpdate = { [weak self] item, release in self?.update(item, release: release) }
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(6 * 60 * 60)) } catch { return }
                self?.checkNow()
            }
        }
        registryChanged(useCase.state())
    }
    deinit { catalogTask?.cancel(); checkTask?.cancel(); installTask?.cancel(); timer?.cancel() }

    func registryChanged(_ state: ExtensionRegistryState) {
        updates = updates.filter { id, update in state.items.contains { $0.manifest.id == id && $0.issue == nil && ($0.pendingVersion ?? $0.manifest.version) < update.version } }
        render()
        if !state.items.isEmpty, Date().timeIntervalSince(lastCheck) >= 6 * 60 * 60 { checkNow() }
    }
    private func render() {
        panel.renderUpdates(updates, checking: checkTask != nil, installing: installTask != nil, statusKey: statusKey, removing: removing)
        panel.catalogView.render(catalogPlugins, installed: Set(useCase.state().items.map { $0.manifest.id }),
            loading: catalogTask != nil, busy: installTask != nil, statusKey: catalogStatusKey)
    }

    func loadCatalog(force: Bool = false) {
        guard catalogTask == nil, installTask == nil, force || !hasLoadedCatalog else { return }
        catalogStatusKey = "Loading Plugin Catalog…"
        catalogTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let plugins = try await self.browse()
                try Task.checkCancellation()
                self.catalogPlugins = plugins.plugins; self.hasLoadedCatalog = true; self.catalogStatusKey = plugins.hasFailures ? "Some Plugins Could Not Be Loaded" : ""
            } catch { self.catalogStatusKey = "Could Not Load Plugin Catalog" }
            self.catalogTask = nil; self.render()
        }
        render()
    }

    private func installFromCatalog(_ plugin: ExtensionCatalogPlugin) {
        guard installTask == nil, catalogTask == nil,
              !useCase.state().items.contains(where: { $0.manifest.id == plugin.release.extensionID }) else { return }
        checkTask?.cancel(); checkTask = nil; checkGeneration = UUID()
        activeInstallID = plugin.release.extensionID
        catalogStatusKey = "Downloading and Verifying Plugin…"
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let prepared = try await self.prepare(plugin.release, plugin.publisherFingerprint)
                try Task.checkCancellation()
                guard !self.useCase.state().items.contains(where: { $0.manifest.id == plugin.release.extensionID }) else { throw ExtensionFailure.staleContext }
                self.catalogStatusKey = "Installing Plugin…"; self.render()
                try await self.install(prepared)
                try Task.checkCancellation()
                await self.useCase.refresh()
                try Task.checkCancellation()
                try await self.useCase.setEnabled(plugin.release.extensionID, enabled: true)
                try await self.activate(plugin.release.extensionID)
                self.catalogStatusKey = "Plugin Installed"
            } catch is CancellationError { self.catalogStatusKey = "Plugin Installation Cancelled" }
            catch { self.catalogStatusKey = "Plugin Installation Failed"; self.onError(error) }
            self.installTask = nil; self.activeInstallID = nil; self.render()
        }
        render()
    }

    func cancelInstallation(for id: ExtensionID) async {
        if activeInstallID == id, let task = installTask { task.cancel(); await task.value }
        checkTask?.cancel(); checkTask = nil; checkGeneration = UUID()
        updates.removeValue(forKey: id)
        render()
    }

    func remove(_ item: ExtensionRegistryItem) {
        guard installTask == nil, !item.isBundled else { return }
        checkTask?.cancel(); checkTask = nil; checkGeneration = UUID()
        removing = true; statusKey = "Uninstalling Plugin…"
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var ownsRemoval = false
            do {
                try await self.useCase.withdrawForRemoval(item)
                ownsRemoval = true
                try await self.uninstall(item)
                self.updates.removeValue(forKey: item.manifest.id)
                self.statusKey = "Plugin Uninstalled"
                self.catalogStatusKey = ""
            } catch { self.statusKey = "Plugin Uninstallation Failed"; self.onError(error) }
            await self.useCase.refresh()
            if ownsRemoval { self.useCase.finishRemoval(item.manifest.id) }
            self.removing = false; self.installTask = nil; self.render()
        }
        render()
    }

    func checkNow() {
        guard checkTask == nil, installTask == nil else { return }
        lastCheck = Date(); statusKey = "Checking for Plugin Updates…"
        let items = useCase.state().items
        let generation = UUID(); checkGeneration = generation
        checkTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let found = try await self.check(items)
                guard self.checkGeneration == generation, !Task.isCancelled else { return }
                self.updates = found
                self.statusKey = self.updates.isEmpty ? "No Plugin Updates Available" : "Plugin Updates Available"
            } catch {
                guard self.checkGeneration == generation, !Task.isCancelled else { return }
                self.statusKey = "Could Not Check for Plugin Updates"
            }
            self.checkTask = nil; self.render()
        }
        render()
    }

    private func update(_ item: ExtensionRegistryItem, release: ExtensionUpdate) {
        guard installTask == nil else { return }
        checkTask?.cancel(); checkTask = nil
        checkGeneration = UUID()
        activeInstallID = item.manifest.id
        statusKey = "Downloading and Verifying Plugin…"
        installTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let token = item.enabled ? try self.useCase.consentReviewToken(for: item.manifest.id) : nil
                let prepared = try await self.prepare(release, item.publisherFingerprint)
                try Task.checkCancellation()
                if let token {
                    let choices = Set(prepared.package.manifest.capabilities)
                    try await self.useCase.approveUpdate(from: token, to: prepared.package, choices: choices)
                } else {
                    guard self.useCase.state().items.contains(where: { $0.packageDigest == item.packageDigest && !$0.enabled }) else { throw ExtensionFailure.staleContext }
                }
                self.statusKey = "Installing Plugin…"; self.render()
                try await self.install(prepared)
                self.updates.removeValue(forKey: item.manifest.id)
                await self.useCase.refresh()
                self.statusKey = self.useCase.state().items.contains(where: { $0.manifest.id == item.manifest.id && $0.pendingVersion != nil }) ? "Plugin Update Will Apply Next Launch" : "Plugin Update Installed"
            } catch is CancellationError { self.statusKey = "Plugin Update Cancelled" }
            catch { self.statusKey = "Plugin Update Failed"; self.onError(error) }
            self.installTask = nil; self.activeInstallID = nil; self.render()
        }
        render()
    }
}
