import AppKit
import UniformTypeIdentifiers

/// Shared dock behavior; each plugin supplies only its renderer and file types.
@MainActor final class DiagramPlugin {
    let panel: DiagramPanel
    private let host: DuckpadHost
    private let definition: DiagramDefinition
    private let strings: DiagramStrings
    private let renderer: any DiagramRendering
    private let settings: DiagramSettings?
    private let settingsURL: URL
    private var task: Task<Void, Never>?
    private var picker: NSSavePanel?
    private var closeMonitor: Any?
    private var viewer: DiagramPreviewWindow?
    private var rendered: DiagramRender?
    private var image: NSImage?
    private var generation: UInt64 = 0
    private var active = true
    init(host: DuckpadHost, config: [String: String], definition: DiagramDefinition, renderer: any DiagramRendering) {
        self.host = host; self.definition = definition; self.renderer = renderer
        strings = DiagramStrings(directory: URL(fileURLWithPath: config["resourceDirectory"] ?? ""),
                                 language: config["language"] ?? "en", name: definition.name)
        settingsURL = URL(fileURLWithPath: config["storageDirectory"] ?? "").appendingPathComponent("runtime.json")
        settings = renderer.hasRuntimeSettings ? DiagramSettings(strings: strings) : nil
        if (try? settingsURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }).map({ $0 <= 16 * 1024 }) == true,
           let data = try? Data(contentsOf: settingsURL), let state = try? JSONDecoder().decode([String: String].self, from: data),
           (state["path"]?.utf8.count ?? 0) <= 4096 {
            settings?.path.stringValue = state["path"] ?? ""
        }
        panel = DiagramPanel(strings: strings, hasRuntimeSettings: renderer.hasRuntimeSettings)
        panel.onRender = { [weak self] in self?.renderDocument() }
        panel.onOpen = { [weak self] in self?.openFile() }
        panel.onSettings = { [weak self] in self?.settings?.showWindow(nil) }
        panel.onExport = { [weak self] format in self?.export(format) }
        panel.onExpand = { [weak self] in self?.expand() }
        panel.onClose = { [weak self] in self?.hide() }
        settings?.onChange = { [weak self] in self?.persistSettings() }
        settings?.onSetup = { [weak self] in
            guard let self else { return }
            self.settings?.path.stringValue = ""
            self.render(self.definition.sample, install: true)
        }
        closeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.active, self.panel.window != nil, event.window === self.panel.window,
                  event.keyCode == 13 || event.charactersIgnoringModifiers?.lowercased() == "w",
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad]) == .control else { return event }
            self.hide(); return nil
        }
        readyStatus()
    }
    func show() -> NSView {
        cancelWork(); panel.setBusy(false, hasImage: image != nil); settings?.setBusy(false); readyStatus()
        return panel
    }
    func setLanguage(_ language: String) {
        strings.language = language; panel.refreshLocalization(); settings?.refreshLocalization(); viewer?.refreshLocalization()
        if task == nil { readyStatus() }
    }
    func stop() {
        guard active else { return }
        active = false; cancelWork()
        viewer?.close(); viewer = nil; settings?.close()
        if let closeMonitor { NSEvent.removeMonitor(closeMonitor) }; closeMonitor = nil
        panel.onRender = nil; panel.onOpen = nil; panel.onSettings = nil; panel.onExport = nil; panel.onExpand = nil; panel.onClose = nil
        settings?.onSetup = nil; settings?.onChange = nil
        image = nil; rendered = nil; panel.preview.display(nil)
    }
    private func cancelWork() {
        generation &+= 1; task?.cancel(); task = nil; renderer.cancel()
        let pending = picker; picker = nil; pending?.cancel(nil)
    }
    private func hide() {
        cancelWork(); settings?.close(); panel.setBusy(false, hasImage: image != nil); settings?.setBusy(false)
        host.closePanel()
    }
    private func readyStatus() {
        panel.setStatus(image == nil ? strings.format("Open a %@ document, then preview it.", definition.name) : strings.text("Ready"))
    }
    @discardableResult private func persistSettings() -> Bool {
        guard let settings else { return true }
        guard settings.path.stringValue.utf8.count <= 4096, !settings.path.stringValue.contains("\0") else {
            report(DiagramFailure("invalidRuntime")); return false
        }
        do {
            try FileManager.default.createDirectory(at: settingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(["path": settings.path.stringValue]).write(to: settingsURL, options: .atomic)
            return true
        } catch { report(DiagramFailure("settingsFailed")); return false }
    }
    private func clearPreview() {
        rendered = nil; image = nil; panel.preview.display(nil); viewer?.preview.display(nil)
        panel.setBusy(false, hasImage: false); settings?.setBusy(false)
    }
    private func renderDocument() {
        guard let source = host.documentText() else { cancelWork(); clearPreview(); report(DiagramFailure("documentUnavailable")); return }
        render(source)
    }
    private func render(_ source: String, install: Bool = false) {
        guard active else { return }
        cancelWork(); clearPreview()
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, source.utf8.count <= 512 * 1024 else {
            report(DiagramFailure("invalidInput")); return
        }
        guard persistSettings() else { return }
        let token = generation
        panel.setBusy(true, hasImage: false); settings?.setBusy(true)
        panel.setStatus(strings.text(install ? "Downloading and verifying the runtime…" : "Rendering locally…"))
        let dark = panel.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let path = settings?.path.stringValue ?? ""
        task = Task { [weak self] in
            guard let self, self.active, self.generation == token, !Task.isCancelled else { return }
            defer { if self.generation == token { self.task = nil; self.panel.setBusy(false, hasImage: self.image != nil); self.settings?.setBusy(false) } }
            do {
                let result = try await self.renderer.render(source, dark: dark, runtimePath: path, install: install)
                guard self.active, self.generation == token, !Task.isCancelled else { return }
                guard let image = NSImage(data: result.png) else { throw DiagramFailure("renderFailed") }
                image.size = NSSize(width: result.width, height: result.height)
                self.rendered = result; self.image = image
                self.panel.preview.display(image); self.viewer?.preview.display(image)
                self.panel.setStatus(self.strings.format("Ready · %d × %d", result.width, result.height))
            } catch {
                guard self.active, self.generation == token, !Task.isCancelled else { return }
                self.report(error)
            }
        }
    }
    private func openFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseFiles = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = definition.fileExtensions.compactMap { UTType(filenameExtension: $0) } + [.plainText]
        let token = generation; picker = panel
        panel.begin { [weak self] response in
            guard let self, self.active, self.generation == token, self.picker === panel else { return }
            self.picker = nil
            guard response == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                guard (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max) <= 512 * 1024 else { throw DiagramFailure("invalidInput") }
                self.render(try String(contentsOf: url, encoding: .utf8))
            } catch { self.report(DiagramFailure("fileFailed")) }
        }
    }
    private func export(_ format: String) {
        guard let result = rendered else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "diagram." + format
        panel.allowedContentTypes = [format == "svg" ? .svg : .png]
        let token = generation; picker = panel
        panel.begin { [weak self] response in
            guard let self, self.active, self.generation == token, self.picker === panel else { return }
            self.picker = nil
            guard response == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource(); defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do { try (format == "svg" ? result.svg : result.png).write(to: url, options: .atomic) }
            catch { self.report(DiagramFailure("fileFailed")) }
        }
    }
    private func expand() {
        guard let image else { return }
        let window = viewer ?? DiagramPreviewWindow(strings: strings)
        viewer = window; window.display(image)
    }
    private func report(_ error: any Error) {
        let failure = error as? DiagramFailure ?? DiagramFailure("renderFailed", error.localizedDescription)
        let message = strings.text("error." + failure.code)
        panel.setStatus(failure.detail.isEmpty ? message : strings.format("%@: %@", message, failure.detail), error: true)
    }
}
