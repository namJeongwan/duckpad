import DuckpadApplication
import DuckpadDomain
import DuckpadLocalization
import Foundation

@MainActor
final class ExtensionListSession {
    let identity: ExtensionServiceRegistration
    weak var useCase: (any ExtensionServiceInvoking)?
    private let storage: any ExtensionServiceStorage
    private var state: Data?
    private var queue: [(event: String, payload: String, query: String, selected: ((String) -> Void)?)] = []
    private var task: Task<Void, Never>?
    private var invalidated = false
    var onUpdate: (([ExtensionListRow], Int, String?) -> Void)?
    init(identity: ExtensionServiceRegistration, useCase: any ExtensionServiceInvoking, storage: any ExtensionServiceStorage) {
        self.identity = identity; self.useCase = useCase; self.storage = storage
    }
    func send(_ event: String, payload: String = "", query: String = "", selected: ((String) -> Void)? = nil) {
        guard !invalidated else { return }
        if event == "capture", payload.utf8.count > ExtensionListProtocol.maximumPayloadBytes { return }
        // The OS clipboard is itself a latest value; coalesce polling and search while
        // keeping explicit pin/delete/select commands in their original order.
        if event == "capture" || event == "query" || event == "preview" { queue.removeAll { $0.event == event } }
        queue.append((event, payload, query, selected))
        drain()
    }
    private func drain() {
        guard task == nil, !invalidated else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            do {
                if self.state == nil { self.state = try await self.storage.load(self.identity) }
                while !self.queue.isEmpty, !self.invalidated, !Task.isCancelled {
                    guard let useCase = self.useCase else { self.invalidate(); return }
                    let item = self.queue.removeFirst()
                    let input = try ExtensionListProtocol.request(state: self.state ?? Data(), event: item.event, payload: item.payload, query: item.query)
                    let output: Data
                    do { output = try await useCase.invokeService(self.identity.command.id, input: input) }
                    catch ExtensionFailure.busy {
                        self.queue.insert(item, at: 0)
                        try await Task.sleep(for: .milliseconds(100)); continue
                    }
                    let result = try ExtensionListProtocol.response(output)
                    guard !self.invalidated, !Task.isCancelled else { return }
                    if result.state != self.state { try await self.storage.save(result.state, for: self.identity) }
                    guard !self.invalidated, !Task.isCancelled else { return }
                    self.state = result.state
                    if item.event != "preview" { self.onUpdate?(result.rows, result.retentionDays, nil) }
                    if item.event == "select" || item.event == "preview" {
                        try await useCase.validateServiceAccess(self.identity.command.id, expectedDigest: self.identity.packageDigest)
                        guard !self.invalidated, !Task.isCancelled else { return }
                        item.selected?(result.selectedText)
                    }
                }
            } catch {
                if !self.invalidated { self.onUpdate?([], 7, L10n.text("Plugin request failed: %1$@", L10n.argument(String(describing: error)))) }
                self.queue.removeAll()
            }
        }
    }
    func invalidate() { invalidated = true; queue.removeAll(); task?.cancel(); onUpdate = nil; state = nil }
}
