import DuckpadDomain
import Foundation

@MainActor public final class TailFileUseCase {
    public enum State: Equatable { case following, reconnecting(attempt: Int, total: Int), failed(FileObservationError) }
    public private(set) var states: [TabID: State] = [:]
    public private(set) var unreadLineCounts: [TabID: Int] = [:]
    public func markFollowed(_ tabID: TabID) { unreadLineCounts.removeValue(forKey: tabID) }
    public var onChange: (() -> Void)?
    private let workspace: ScratchWorkspaceUseCase
    private let editor: any EditorPort
    private let reader: any FileObservationReading
    private var tasks: [TabID: Task<Void, Never>] = [:]
    private var growthBytes: [TabID: Int] = [:]
    private var generations: [TabID: UUID] = [:]
    private let retryPolicy: RemoteConnectionRetryPolicy
    private let interval: Duration
    public static let maximumGrowthBytes = 64 * 1_024 * 1_024

    public init(workspace: ScratchWorkspaceUseCase, editor: any EditorPort,
                reader: any FileObservationReading, interval: Duration = .milliseconds(250),
                retryPolicy: RemoteConnectionRetryPolicy = .init()) {
        self.workspace = workspace; self.editor = editor; self.reader = reader; self.interval = interval; self.retryPolicy = retryPolicy
    }
    deinit { for task in tasks.values { task.cancel() } }

    public func start(tabID: TabID) async throws {
        guard let observed = editor as? any ObservedFileEditorPort,
              let context = workspace.fileContext(tabID: tabID), var binding = context.binding else {
            throw FileObservationError.editorUnavailable
        }
        guard workspace.snapshot().tabs.first(where: { $0.id == tabID })?.isDirty == false else { throw FileObservationError.dirtyDocument }
        guard binding.encoding == .utf8, binding.binaryByteCount == nil else { throw FileObservationError.unsupportedEncoding }
        cancel(tabID)
        let generation = UUID()
        generations[tabID] = generation
        binding.tailMode = true
        guard await workspace.startObservingFile(expected: context, binding: binding,
            isCurrent: { self.generations[tabID] == generation }) else {
            if generations[tabID] == generation { generations.removeValue(forKey: tabID) }
            try Task.checkCancellation()
            if workspace.snapshot().tabs.first(where: { $0.id == tabID })?.isDirty == true { throw FileObservationError.dirtyDocument }
            return
        }
        guard generations[tabID] == generation, workspace.fileContext(tabID: tabID)?.binding == binding else { return }
        observed.followObservedFileEnd(in: context.buffer.bufferID)
        states[tabID] = .following; onChange?()
        let source = binding.remoteFile.map(FileObservationSource.ssh) ?? .local(binding.canonicalPath)
        let cursor = FileObservationCursor(identity: binding.remoteFile == nil
            ? "\(binding.observedIdentity.device):\(binding.observedIdentity.inode)"
            : binding.observedIdentity.contentToken,
            offset: binding.observedIdentity.byteCount)
        tasks[tabID] = Task { [weak self] in
            await self?.follow(tabID: tabID, source: source, cursor: cursor, generation: generation)
        }
    }

    private func follow(tabID: TabID, source: FileObservationSource, cursor initial: FileObservationCursor, generation: UUID) async {
        var cursor = initial, decoder = FileTailUTF8Decoder(), growth = growthBytes[tabID] ?? 0, retry = 0
        while !Task.isCancelled, generations[tabID] == generation,
              let context = workspace.fileContext(tabID: tabID), context.binding?.tailMode == true {
            do {
                let read = try await reader.read(source, after: cursor, maximumBytes: 64 * 1_024 - 4)
                guard !Task.isCancelled, generations[tabID] == generation,
                      workspace.fileContext(tabID: tabID) == context else { break }
                var nextDecoder = decoder
                let text = try nextDecoder.decode(read.data, reset: read.reset)
                if !text.isEmpty || read.reset {
                    if !read.reset, growth > Self.maximumGrowthBytes - text.count { throw FileObservationError.tooLarge }
                    guard let observed = editor as? any ObservedFileEditorPort else { throw FileObservationError.editorUnavailable }
                    let ids = read.cursor.identity.split(separator: ":")
                    let identity = FileIdentity(canonicalPath: context.binding!.canonicalPath,
                        device: ids.first.flatMap { UInt64($0) } ?? 0, inode: ids.last.flatMap { UInt64($0) } ?? 0,
                        byteCount: read.cursor.offset - UInt64(nextDecoder.pendingByteCount), modifiedNanoseconds: 0,
                        contentToken: read.cursor.identity)
                    let wasFollowing = observed.isObservedFileFollowingEnd(in: context.buffer.bufferID)
                    guard workspace.applyObservedFileUpdate(tabID: tabID, expected: context, identity: identity, install: {
                        observed.applyObservedUTF8(text, to: $0, reset: read.reset)
                    }) else {
                        try await Task.sleep(for: .milliseconds(10))
                        continue
                    }
                    if wasFollowing || read.reset { unreadLineCounts.removeValue(forKey: tabID) }
                    else { unreadLineCounts[tabID, default: 0] += text.reduce(0) { $0 + ($1 == 10 ? 1 : 0) } }
                    onChange?()
                }
                retry = 0
                cursor = read.cursor; decoder = nextDecoder
                growth = read.reset ? text.count : growth + text.count
                growthBytes[tabID] = growth
                let wasFailed = states[tabID] != .following
                states[tabID] = .following
                if wasFailed { onChange?() }
                if read.hasMore { await Task.yield() }
                else { try await Task.sleep(for: source.isRemote ? .seconds(1) : interval) }
            } catch is CancellationError { break }
            catch {
                guard !Task.isCancelled, generations[tabID] == generation else { break }
                let failure = (error as? FileObservationError) ?? .unavailable
                let delay: Duration
                if source.isRemote {
                    guard let next = retryPolicy.delay(after: error, retry: retry) else {
                        states[tabID] = .failed(failure); onChange?(); break
                    }
                    delay = next; retry += 1
                    states[tabID] = .reconnecting(attempt: retry, total: retryPolicy.delays.count)
                } else {
                    states[tabID] = .failed(failure)
                    if failure == .tooLarge { onChange?(); break }
                    delay = .seconds(2)
                }
                onChange?()
                // Retain cursor and partial UTF-8 bytes across automatic retries.
                // Cancellation, Stop and tab closure must never reconnect.
                do { try await Task.sleep(for: delay) } catch { break }
            }
        }
        if generations[tabID] == generation { tasks.removeValue(forKey: tabID) }
    }

    public func canRetry(tabID: TabID) -> Bool {
        guard case .failed(let error) = states[tabID],
              workspace.fileContext(tabID: tabID)?.binding?.remoteFile != nil else { return false }
        return RemoteConnectionRetryPolicy.isConnectionFailure(error)
    }

    /// Resume a failed connection without restarting observation. The committed
    /// cursor excludes partial UTF-8, which is re-read; viewport, unread count
    /// and the current observation's growth budget stay intact.
    public func retry(tabID: TabID) {
        guard canRetry(tabID: tabID), let binding = workspace.fileContext(tabID: tabID)?.binding,
              binding.tailMode == true, let remote = binding.remoteFile else { return }
        tasks.removeValue(forKey: tabID)?.cancel()
        let generation = UUID(); generations[tabID] = generation
        let cursor = FileObservationCursor(identity: binding.observedIdentity.contentToken, offset: binding.observedIdentity.byteCount)
        states[tabID] = .following
        tasks[tabID] = Task { [weak self] in
            await self?.follow(tabID: tabID, source: .ssh(remote), cursor: cursor, generation: generation)
        }
        onChange?()
    }

    public func clear(tabID: TabID) async throws {
        guard let context = workspace.fileContext(tabID: tabID), context.binding?.tailMode == true,
              let observed = editor as? any ObservedFileEditorPort else { throw FileObservationError.editorUnavailable }
        cancel(tabID)
        guard workspace.applyObservedFileUpdate(tabID: tabID, expected: context, identity: context.binding!.observedIdentity,
            install: { observed.applyObservedUTF8(Data(), to: $0, reset: true) }) else { throw FileObservationError.editorUnavailable }
        try await start(tabID: tabID)
    }

    public func cancel(_ tabID: TabID) {
        generations.removeValue(forKey: tabID)
        tasks.removeValue(forKey: tabID)?.cancel()
        states.removeValue(forKey: tabID)
        unreadLineCounts.removeValue(forKey: tabID)
        growthBytes.removeValue(forKey: tabID)
        onChange?()
    }
    public func cancelAll() { for id in Array(generations.keys) { cancel(id) } }
    public func reconcileTabs() {
        let ids = Set(workspace.snapshot().tabs.map(\.id))
        for id in Array(generations.keys) where !ids.contains(id) { cancel(id) }
    }
}

private extension FileObservationSource {
    var isRemote: Bool { if case .ssh = self { return true }; return false }
}
