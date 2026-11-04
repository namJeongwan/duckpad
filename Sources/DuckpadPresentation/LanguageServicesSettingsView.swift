import AppKit
import DuckpadDomain
import DuckpadApplication
import DuckpadLocalization

/// Generic preferences. The persisted SessionID owns workspace and folder overrides.
@MainActor final class LanguageServicesSettingsView: NSStackView, NSTextFieldDelegate {
    var onChange: (([String: LanguageServiceSettings]) -> Void)?
    var onLanguageChange: ((LanguageServerRegistration) -> Void)?
    private var settings: [String: LanguageServiceSettings] = [:]
    private var registrations: [LanguageServerRegistration] = []
    private var conflictingLanguages: Set<String> = []
    private var workspaceID: SessionID?
    private var folders: [LanguageServiceFolder] = []
    private var preferredFolderID: String?
    private var projectRoot: String?
    private var context: LanguageServerLaunchContext?
    private var unavailable = false
    private var catalog = L10n.catalog
    private var bindings: [(LocalizationCatalog) -> Void] = []
    private let language = NSPopUpButton(frame: .zero, pullsDown: false)
    private let scope = NSPopUpButton(frame: .zero, pullsDown: false)
    private let folder = NSPopUpButton(frame: .zero, pullsDown: false)
    private let server = NSPopUpButton(frame: .zero, pullsDown: false)
    private let interpreter = NSTextField(string: "")
    private let location = NSTextField(labelWithString: "")
    private let active = NSTextField(wrappingLabelWithString: "")
    private let command = NSTextField(wrappingLabelWithString: "")
    private let install = NSTextField(wrappingLabelWithString: "")
    private let issue = NSTextField(wrappingLabelWithString: "")
    private let empty = NSTextField(wrappingLabelWithString: "")
    private let choose = NSButton(title: "", target: nil, action: nil)
    private let apply = NSButton(title: "", target: nil, action: nil)
    private var folderRow: NSView!
    private var interpreterRow: NSView!
    private var issueKey: String?
    private var enabled = true
    private var hasDraft = false
    var selectedRegistration: LanguageServerRegistration? {
        registrations.first { $0.settingsKey == language.selectedItem?.representedObject as? String }
    }
    private var selectedFolder: LanguageServiceFolder? {
        folders.first { $0.id == folder.selectedItem?.representedObject as? String }
    }
    private var selectedScope: Int { scope.indexOfSelectedItem }

    init() {
        super.init(frame: .zero)
        orientation = .vertical; alignment = .leading; spacing = 10
        for (view, id) in [(language, "language"), (scope, "scope"), (folder, "folder"), (server, "server"), (interpreter, "interpreter"), (apply, "apply"), (active, "active"), (command, "command")] as [(NSView, String)] {
            view.identifier = .init("duckpad.settings.language-services." + id)
        }
        for title in ["All defaults", "Current workspace", "Selected folder"] {
            scope.addItem(withTitle: ""); let item = scope.lastItem!
            localize { item.title = $0.text(title) }
        }
        language.target = self; language.action = #selector(languageChanged)
        scope.target = self; scope.action = #selector(scopeChanged)
        folder.target = self; folder.action = #selector(folderChanged)
        server.target = self; server.action = #selector(serverChanged)
        interpreter.delegate = self
        folder.widthAnchor.constraint(lessThanOrEqualToConstant: 440).isActive = true
        interpreter.widthAnchor.constraint(equalToConstant: 300).isActive = true
        choose.target = self; choose.action = #selector(chooseInterpreter)
        apply.target = self; apply.action = #selector(applySettings)
        localize { [choose, apply, interpreter] catalog in
            choose.title = catalog.text("Choose…")
            choose.setAccessibilityLabel(catalog.text("Choose interpreter…"))
            apply.title = catalog.text("Apply language settings")
            interpreter.placeholderString = catalog.text("Automatic environment detection")
            interpreter.setAccessibilityLabel(catalog.text("Interpreter"))
        }
        empty.textColor = .secondaryLabelColor; addArrangedSubview(empty)
        _ = row("Language", language)
        _ = row("Settings scope", scope)
        folderRow = row("Folder", folder)
        location.lineBreakMode = .byTruncatingMiddle; location.textColor = .secondaryLabelColor
        addArrangedSubview(location)
        _ = row("Language server", server)
        interpreterRow = row("Interpreter", interpreter, choose)
        active.textColor = .secondaryLabelColor; addArrangedSubview(active)
        addArrangedSubview(command)
        install.textColor = .secondaryLabelColor; addArrangedSubview(install)
        let note = NSTextField(wrappingLabelWithString: ""); note.textColor = .secondaryLabelColor
        localize { note.stringValue = $0.text("Existing environments are used. Project environments and packages are not created or installed automatically.") }
        addArrangedSubview(note); addArrangedSubview(apply)
        issue.textColor = .systemRed; addArrangedSubview(issue)
        for field in [location, active, command, install, empty, note, issue] { field.widthAnchor.constraint(lessThanOrEqualToConstant: 560).isActive = true }
        render([:])
    }
    required init?(coder: NSCoder) { nil }
    private func localize(_ binding: @escaping (LocalizationCatalog) -> Void) { bindings.append(binding); binding(catalog) }
    private func row(_ key: String, _ views: NSView...) -> NSView {
        let label = NSTextField(labelWithString: ""); localize { label.stringValue = $0.text(key) }
        let row = NSStackView(views: [label] + views); row.spacing = 10; addArrangedSubview(row)
        if let control = views.first as? NSControl { localize { control.setAccessibilityLabel($0.text(key)) } }
        return row
    }
    func configureRegistrations(_ values: [LanguageServerRegistration], preferredLanguageID: String? = nil, conflictingLanguages: Set<String> = []) {
        if registrations == values, self.conflictingLanguages == conflictingLanguages,
           preferredLanguageID == nil || selectedRegistration?.service.languageID == preferredLanguageID { return }
        let previous = selectedRegistration?.settingsKey
        registrations = values; self.conflictingLanguages = conflictingLanguages
        language.removeAllItems()
        for value in values { language.addItem(withTitle: value.service.displayName); language.lastItem?.representedObject = value.settingsKey }
        let selected = values.first { $0.service.languageID == preferredLanguageID }?.settingsKey ?? previous
        if let item = language.itemArray.first(where: { $0.representedObject as? String == selected }) { language.select(item) }
        context = nil; unavailable = false; issueKey = nil; hasDraft = false
        renderChoice()
    }
    func configureWorkspace(id: SessionID?, folders: [LanguageServiceFolder], selectedFolderID: String? = nil,
                            projectRoot: String? = nil, context: LanguageServerLaunchContext? = nil, unavailable: Bool = false) {
        let ownerChanged = workspaceID != id
        let oldFolder = selectedFolder?.id
        let draftServer = server.selectedItem?.representedObject as? String
        let draftPath = interpreter.stringValue
        let preserve = !ownerChanged && hasDraft
        let previousPreference = preferredFolderID
        workspaceID = id; self.folders = folders; preferredFolderID = selectedFolderID
        self.projectRoot = projectRoot
        self.context = context?.workspaceID == id ? context : nil
        self.unavailable = unavailable; issueKey = nil
        if ownerChanged { scope.selectItem(at: id == nil ? 0 : 1); hasDraft = false }
        let target = ownerChanged || previousPreference != selectedFolderID ? selectedFolderID : oldFolder
        folder.removeAllItems()
        for value in folders {
            let duplicate = folders.filter { $0.displayName == value.displayName }.count > 1
            folder.addItem(withTitle: duplicate ? value.path : value.displayName)
            folder.lastItem?.representedObject = value.id
        }
        if let item = folder.itemArray.first(where: { $0.representedObject as? String == target }) { folder.select(item) }
        if selectedScope == 2 && folders.isEmpty { scope.selectItem(at: id == nil ? 0 : 1) }
        if selectedScope == 1 && id == nil { scope.selectItem(at: 0) }
        renderChoice()
        if preserve, oldFolder == selectedFolder?.id || selectedScope != 2 {
            if let item = server.itemArray.first(where: { $0.representedObject as? String == draftServer }) { server.select(item) }
            interpreter.stringValue = draftPath; hasDraft = true; updateStatus()
        }
    }
    func render(_ settings: [String: LanguageServiceSettings]) {
        if hasDraft, let key = selectedRegistration?.settingsKey {
            let previous = self.settings[key] ?? .init(), next = settings[key] ?? .init()
            let unchanged = workspaceID.map { previous.isolated(to: $0) == next.isolated(to: $0) } ?? (previous == next)
            if unchanged { self.settings = settings; updateStatus(); return }
        }
        if let key = selectedRegistration?.settingsKey {
            let previous = self.settings[key] ?? .init(), next = settings[key] ?? .init()
            let changed = workspaceID.map { previous.isolated(to: $0) != next.isolated(to: $0) } ?? (previous != next)
            if changed { context = nil }
        }
        self.settings = settings; hasDraft = false
        renderChoice()
    }
    private func choice(_ current: LanguageServiceSettings) -> LanguageProjectSettings {
        guard selectedScope != 0, let workspaceID else { return .init(serverID: current.serverID, interpreterPath: current.interpreterPath) }
        let workspace = current.workspace(workspaceID)
        if selectedScope == 2, let selectedFolder { return workspace.folderSettings(selectedFolder, projectRoot: projectRoot.flatMap { selectedFolder.contains($0) ? $0 : nil } ?? selectedFolder.path) }
        return .init(serverID: workspace.serverID, interpreterPath: workspace.interpreterPath)
    }
    private func renderChoice() {
        empty.isHidden = !registrations.isEmpty && conflictingLanguages.isEmpty
        server.removeAllItems()
        server.addItem(withTitle: catalog.text("Use default server")); server.lastItem?.representedObject = "inherit"
        if let registration = selectedRegistration {
            for value in registration.service.servers { server.addItem(withTitle: value.id); server.lastItem?.representedObject = value.id }
            server.addItem(withTitle: catalog.text("Disabled")); server.lastItem?.representedObject = "disabled"
            let selected = choice(settings[registration.settingsKey] ?? .init())
            let raw = selected.serverID ?? "inherit"
            if !server.itemArray.contains(where: { $0.representedObject as? String == raw }) {
                server.addItem(withTitle: raw); server.lastItem?.representedObject = raw
            }
            server.select(server.itemArray.first { $0.representedObject as? String == raw })
            interpreter.stringValue = selected.interpreterPath
            interpreterRow.isHidden = registration.service.interpreter == nil
            active.isHidden = registration.service.interpreter == nil
        } else { interpreterRow.isHidden = true; active.isHidden = true; interpreter.stringValue = "" }
        scope.item(at: 1)?.isEnabled = workspaceID != nil
        scope.item(at: 2)?.isEnabled = workspaceID != nil && !folders.isEmpty
        folderRow.isHidden = selectedScope != 2
        updateStatus(); setControlsEnabled(enabled)
    }
    func setControlsEnabled(_ value: Bool) {
        enabled = value
        language.isEnabled = value && !registrations.isEmpty
        for control in [scope, folder, server, interpreter, choose, apply] as [NSControl] { control.isEnabled = value && selectedRegistration != nil }
    }
    func refreshLocalization(_ value: LocalizationCatalog) {
        catalog = value; for binding in bindings { binding(value) }
        server.itemArray.first { $0.representedObject as? String == "inherit" }?.title = value.text("Use default server")
        server.itemArray.first { $0.representedObject as? String == "disabled" }?.title = value.text("Disabled")
        updateStatus()
    }
    private func updateStatus() {
        empty.stringValue = catalog.text(conflictingLanguages.isEmpty ? "Install and enable a language support plugin in Extensions." : "Multiple enabled plugins provide the same language. Disable one of them.")
        location.isHidden = selectedScope != 2
        location.stringValue = selectedScope == 2 ? selectedFolder?.path ?? "" : ""
        let relevant = selectedScope != 2 || context?.folderID == selectedFolder?.id
        active.stringValue = catalog.text("Active interpreter: %1$@", arguments: [relevant ? context?.interpreterPath ?? catalog.text("Automatic") : catalog.text("Automatic")])
        if unavailable { issueKey = "Language server is unavailable. Check the server installation and interpreter path." }
        issue.stringValue = issueKey.map { catalog.text($0) } ?? ""
        guard let registration = selectedRegistration else { command.stringValue = ""; install.stringValue = ""; return }
        let current = settings[registration.settingsKey] ?? .init()
        let inherited: String
        if selectedScope == 2, let workspaceID { inherited = current.workspace(workspaceID).serverID ?? current.serverID ?? registration.service.defaultServerID }
        else if selectedScope == 1 { inherited = current.serverID ?? registration.service.defaultServerID }
        else { inherited = registration.service.defaultServerID }
        let selected = server.selectedItem?.representedObject as? String ?? "inherit"
        let id = selected == "inherit" ? inherited : selected
        let executable = registration.service.servers.first { $0.id == id }
        command.stringValue = catalog.text("Server command: %1$@", arguments: [executable?.command.joined(separator: " ") ?? catalog.text("Disabled")])
        install.stringValue = executable.flatMap { $0.installHint.isEmpty ? nil : $0 }.map { catalog.text("Install command: %1$@", arguments: [$0.installHint]) } ?? ""
    }
    public func controlTextDidChange(_ notification: Notification) { hasDraft = true }
    @objc private func languageChanged() {
        context = nil; unavailable = false; issueKey = nil; hasDraft = false
        renderChoice(); if let selectedRegistration { onLanguageChange?(selectedRegistration) }
    }
    @objc private func scopeChanged() { hasDraft = false; issueKey = nil; renderChoice() }
    @objc private func folderChanged() { hasDraft = false; issueKey = nil; renderChoice() }
    @objc private func serverChanged() { hasDraft = true; updateStatus() }
    @objc private func chooseInterpreter() {
        guard let window else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false; panel.canChooseFiles = true
        panel.allowsMultipleSelection = false; panel.resolvesAliases = false; panel.message = catalog.text("Choose interpreter…")
        panel.beginSheetModal(for: window) { [weak self] result in
            if result == .OK, let url = panel.url { self?.interpreter.stringValue = url.path; self?.hasDraft = true }
        }
    }
    @objc private func applySettings() {
        guard let registration = selectedRegistration else { return }
        var proposed = settings, current = settings[registration.settingsKey] ?? .init()
        let raw = server.selectedItem?.representedObject as? String ?? "inherit"
        let value = LanguageProjectSettings(serverID: raw == "inherit" ? nil : raw, interpreterPath: interpreter.stringValue.trimmingCharacters(in: .whitespacesAndNewlines))
        guard value.isValid else {
            issueKey = "Enter an absolute interpreter path, or leave it empty for automatic detection."
            issue.stringValue = catalog.text(issueKey!); return
        }
        if selectedScope == 0 { current.serverID = value.serverID; current.interpreterPath = value.interpreterPath }
        else if let workspaceID {
            var workspace = current.workspace(workspaceID)
            if selectedScope == 2, let selectedFolder { workspace.folders[selectedFolder.id] = value }
            else { workspace.serverID = value.serverID; workspace.interpreterPath = value.interpreterPath }
            // Persist even an empty override snapshot so clearing never reimports legacy path choices.
            current.workspaces[workspaceID.rawValue.uuidString] = workspace
        } else { return }
        proposed[registration.settingsKey] = current
        issueKey = nil; hasDraft = false; onChange?(proposed)
    }
}
