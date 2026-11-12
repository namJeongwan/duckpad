import Foundation

@MainActor protocol DiagramRendering: AnyObject {
    var hasRuntimeSettings: Bool { get }
    func render(_ source: String, dark: Bool, runtimePath: String, install: Bool) async throws -> DiagramRender
    func cancel()
}
