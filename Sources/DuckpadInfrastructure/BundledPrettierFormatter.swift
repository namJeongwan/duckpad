import DuckpadApplication
import Foundation

/// Runs the bundled formatter in WebKit's separate content process. One runtime
/// is reused for nearby requests and discarded after a bounded idle interval.
@MainActor
public final class BundledPrettierFormatter: DocumentFormatting {
    public static let maximumInputBytes = 1_024 * 1_024
    private let timeout: Duration
    private let idleTimeout: Duration
    private let runtimeFactory: (String, Duration) -> PrettierWebRuntime
    private var script: String?
    private var scriptName: String?
    private var runtime: PrettierWebRuntime?
    private var runtimeIncludesAllParsers = false
    private var idleTask: Task<Void, Never>?
    private var isFormatting = false
    private(set) var runtimeStartCount = 0
    var hasResidentRuntime: Bool { runtime?.isReusable == true }

    public convenience init(timeout: Duration = .seconds(15), idleTimeout: Duration = .seconds(30)) {
        self.init(timeout: timeout, idleTimeout: idleTimeout, runtimeFactory: { PrettierWebRuntime(script: $0, timeout: $1) })
    }

    init(timeout: Duration, idleTimeout: Duration, runtimeFactory: @escaping (String, Duration) -> PrettierWebRuntime) {
        self.timeout = timeout
        self.idleTimeout = idleTimeout
        self.runtimeFactory = runtimeFactory
    }

    public func format(_ request: FormattingRequest) async throws -> String {
        guard request.text.utf8.count <= Self.maximumInputBytes else { throw FormattingFailure.tooLarge }
        try Task.checkCancellation()
        // A caller deadline cannot interrupt synchronous JavaScript in WebKit.
        // Wait for an invalidated evaluation to drain before creating its replacement.
        guard !isFormatting, runtime?.isEvaluating != true else { throw FormattingFailure.busy }
        isFormatting = true
        idleTask?.cancel()
        idleTask = nil
        defer {
            isFormatting = false
            scheduleIdleRelease()
        }
        let requiresAllParsers = !["json", "jsonc", "json5"].contains(request.parser)
        if runtime?.isReusable != true || (requiresAllParsers && !runtimeIncludesAllParsers) {
            let name = requiresAllParsers ? "formatter" : "formatter-json"
            if scriptName != name || script == nil {
                guard let url = DuckpadInfrastructureResources.bundle.url(forResource: name, withExtension: "js", subdirectory: "Formatter") else {
                    throw FormattingFailure.unavailable
                }
                script = try String(contentsOf: url, encoding: .utf8)
                scriptName = name
            }
            // Upgrade once if another language is requested. Keep one runtime;
            // the full bundle continues to handle subsequent JSON requests.
            runtime?.invalidate()
            runtime = runtimeFactory(script!, timeout)
            runtimeIncludesAllParsers = requiresAllParsers
            runtimeStartCount += 1
        }
        let runtime = runtime!
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try await runtime.format(request, id: requestID)
        } onCancel: {
            Task { @MainActor in runtime.cancel(id: requestID) }
        }
    }

    private func scheduleIdleRelease() {
        guard runtime?.isReusable == true else {
            if runtime?.isEvaluating != true { runtime = nil }
            return
        }
        idleTask = Task { @MainActor [weak self, idleTimeout] in
            do { try await Task.sleep(for: idleTimeout) } catch { return }
            guard let self, !self.isFormatting else { return }
            self.runtime?.invalidate()
            self.runtime = nil
            self.idleTask = nil
        }
    }
}
