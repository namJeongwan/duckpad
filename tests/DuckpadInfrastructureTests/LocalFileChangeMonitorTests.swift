import DuckpadInfrastructure
import Foundation
import Testing

@Test @MainActor func liveFileMonitorDetectsInPlaceAtomicDeleteAndRecreateWithoutRepeatedEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("duckpad-live-monitor-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let file = root.appendingPathComponent("file.txt")
    try Data("one".utf8).write(to: file)
    let monitor = LocalFileChangeMonitor(interval: .milliseconds(15))
    defer { monitor.stop() }
    var events = 0
    monitor.onChange = { paths in if paths.contains(file.path) { events += 1 } }
    monitor.watch(paths: [file.path])
    func waitFor(_ count: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while events < count && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(events == count)
    }
    try await waitFor(1)
    try await Task.sleep(for: .milliseconds(100))
    #expect(events == 1)
    try Data("two".utf8).write(to: file)
    try await waitFor(2)
    try Data("replacement".utf8).write(to: file, options: .atomic)
    try await waitFor(3)
    try FileManager.default.removeItem(at: file)
    try await waitFor(4)
    try Data("recreated".utf8).write(to: file)
    try await waitFor(5)
    monitor.stop()
    try Data("stopped".utf8).write(to: file)
    try await Task.sleep(for: .milliseconds(100))
    #expect(events == 5)
}
