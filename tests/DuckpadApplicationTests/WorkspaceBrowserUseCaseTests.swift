import DuckpadApplication
import DuckpadDomain
import Foundation
import Testing

private actor MemoryWorkspaceRootStore: WorkspaceRootStore {
    var roots: [WorkspaceRoot]
    var entries: [WorkspaceBrowserEntry]
    private var blockNextAdd = false
    private var blockedAddEntered = false
    private var releaseBlockedAdd = false

    init(roots: [WorkspaceRoot] = [], entries: [WorkspaceBrowserEntry] = []) {
        self.roots = roots
        self.entries = entries
    }

    func loadRoots() async throws(WorkspaceBrowserFailure) -> [WorkspaceRoot] { roots }

    func addRoot(_ url: URL) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        if blockNextAdd {
            blockNextAdd = false
            blockedAddEntered = true
            while !releaseBlockedAdd { await Task.yield() }
        }
        if roots.contains(where: { $0.canonicalPath == url.path }) { throw .duplicateRoot(url.path) }
        let root = WorkspaceRoot(canonicalPath: url.path, displayName: url.lastPathComponent)
        roots.append(root)
        return root
    }

    func removeRoot(_ id: WorkspaceRootID) async throws(WorkspaceBrowserFailure) {
        guard roots.contains(where: { $0.id == id }) else { throw .unknownRoot(id) }
        roots.removeAll { $0.id == id }
    }

    func children(rootID: WorkspaceRootID, relativeDirectory: String) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] {
        entries.filter {
            let parent = $0.relativePath.split(separator: "/").dropLast().joined(separator: "/")
            return $0.rootID == rootID && parent == relativeDirectory
        }
    }

    func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead {
        let url = URL(fileURLWithPath: "/root").appendingPathComponent(entry.relativePath)
        return WorkspaceFileRead(
            url: url,
            result: FileReadResult(
                data: Data(),
                identity: FileIdentity(
                    canonicalPath: url.path,
                    device: 1,
                    inode: 1,
                    byteCount: 0,
                    modifiedNanoseconds: 0,
                    contentToken: ""
                )
            )
        )
    }

    func updateNavigation(
        rootID: WorkspaceRootID,
        expandedRelativePaths: [String],
        selectedRelativePath: String?
    ) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        guard let index = roots.firstIndex(where: { $0.id == rootID }) else { throw .unknownRoot(rootID) }
        roots[index] = WorkspaceRoot(
            id: roots[index].id,
            canonicalPath: roots[index].canonicalPath,
            displayName: roots[index].displayName,
            expandedRelativePaths: expandedRelativePaths,
            selectedRelativePath: selectedRelativePath
        )
        return roots[index]
    }

    func armBlockedAdd() {
        blockNextAdd = true
        blockedAddEntered = false
        releaseBlockedAdd = false
    }

    func waitForBlockedAdd() async {
        while !blockedAddEntered { await Task.yield() }
    }

    func releaseAdd() { releaseBlockedAdd = true }

    func storedRoots() -> [WorkspaceRoot] { roots }
}

private struct CorruptWorkspaceRootStore: WorkspaceRootStore {
    func loadRoots() async throws(WorkspaceBrowserFailure) -> [WorkspaceRoot] {
        throw .corruptStore("damaged")
    }
    func addRoot(_ url: URL) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        throw .corruptStore("damaged")
    }
    func removeRoot(_ id: WorkspaceRootID) async throws(WorkspaceBrowserFailure) {
        throw .corruptStore("damaged")
    }
    func children(
        rootID: WorkspaceRootID,
        relativeDirectory: String
    ) async throws(WorkspaceBrowserFailure) -> [WorkspaceBrowserEntry] {
        throw .corruptStore("damaged")
    }
    func readFile(_ entry: WorkspaceBrowserEntry) async throws(WorkspaceBrowserFailure) -> WorkspaceFileRead {
        throw .corruptStore("damaged")
    }
    func updateNavigation(
        rootID: WorkspaceRootID,
        expandedRelativePaths: [String],
        selectedRelativePath: String?
    ) async throws(WorkspaceBrowserFailure) -> WorkspaceRoot {
        throw .corruptStore("damaged")
    }
}

@Suite(.serialized)
struct WorkspaceBrowserUseCaseTests {
    @Test @MainActor
    func rootsAndNavigationArePublishedThroughTypedState() async throws {
        let rootID = WorkspaceRootID()
        let root = WorkspaceRoot(id: rootID, canonicalPath: "/tmp/duck", displayName: "duck")
        let entry = WorkspaceBrowserEntry(rootID: rootID, relativePath: "Sources", name: "Sources", kind: .directory)
        let store = MemoryWorkspaceRootStore(roots: [root], entries: [entry])
        let useCase = WorkspaceBrowserUseCase(store: store)
        var observed: [WorkspaceBrowserState] = []
        useCase.onStateChange = { observed.append($0) }

        #expect(await useCase.start() == .ready([root]))
        #expect(observed.first == .loading)
        #expect(try await useCase.children(rootID: rootID, relativeDirectory: "") == [entry])
        await useCase.updateNavigation(
            rootID: rootID,
            expandedRelativePaths: ["", "Sources"],
            selectedRelativePath: "Sources/main.swift"
        )
        #expect(useCase.roots.first?.expandedRelativePaths == ["", "Sources"])
        #expect(useCase.roots.first?.selectedRelativePath == "Sources/main.swift")

        #expect(await useCase.removeRoot(rootID) == .ready([]))
    }

    @Test @MainActor
    func duplicateAndRootLimitFailuresAreExplicit() async {
        let existing = WorkspaceRoot(canonicalPath: "/tmp/duck", displayName: "duck")
        let duplicate = WorkspaceBrowserUseCase(store: MemoryWorkspaceRootStore(roots: [existing]))
        _ = await duplicate.start()
        #expect(await duplicate.addRoot(URL(fileURLWithPath: existing.canonicalPath)) == .failed(.duplicateRoot(existing.canonicalPath)))

        let roots = (0..<WorkspaceRoot.maximumRootCount).map {
            WorkspaceRoot(canonicalPath: "/tmp/root-\($0)", displayName: "root-\($0)")
        }
        let capped = WorkspaceBrowserUseCase(store: MemoryWorkspaceRootStore(roots: roots))
        _ = await capped.start()
        #expect(await capped.addRoot(URL(fileURLWithPath: "/tmp/overflow")) == .failed(.rootLimitExceeded(WorkspaceRoot.maximumRootCount)))
    }

    @Test @MainActor
    func fileResolutionRejectsDirectoriesAndForeignRootsBeforeStore() async {
        let root = WorkspaceRoot(canonicalPath: "/tmp/duck", displayName: "duck")
        let useCase = WorkspaceBrowserUseCase(store: MemoryWorkspaceRootStore(roots: [root]))
        _ = await useCase.start()
        let directory = WorkspaceBrowserEntry(rootID: root.id, relativePath: "Sources", name: "Sources", kind: .directory)
        await #expect(throws: WorkspaceBrowserFailure.invalidPath("Sources")) {
            _ = try await useCase.readFile(directory)
        }
        let foreign = WorkspaceBrowserEntry(rootID: WorkspaceRootID(), relativePath: "file.txt", name: "file.txt", kind: .file)
        await #expect(throws: WorkspaceBrowserFailure.invalidPath("file.txt")) {
            _ = try await useCase.readFile(foreign)
        }
    }

    @Test @MainActor
    func concurrentAddsCannotPublishAStaleRootList() async {
        let store = MemoryWorkspaceRootStore()
        let useCase = WorkspaceBrowserUseCase(store: store)
        _ = await useCase.start()
        await store.armBlockedAdd()

        let first = Task { @MainActor in
            await useCase.addRoot(URL(fileURLWithPath: "/tmp/A", isDirectory: true))
        }
        await store.waitForBlockedAdd()
        let second = Task { @MainActor in
            await useCase.addRoot(URL(fileURLWithPath: "/tmp/B", isDirectory: true))
        }
        for _ in 0..<100 { await Task.yield() }
        await store.releaseAdd()
        _ = await first.value
        _ = await second.value

        #expect(Set(useCase.roots.map(\.displayName)) == Set(["A", "B"]))
        #expect(Set(await store.storedRoots().map(\.displayName)) == Set(["A", "B"]))
    }

    @Test @MainActor
    func suspendedCancelledMutationDoesNotPublishAndReconcilesWhenResumed() async {
        let store = MemoryWorkspaceRootStore()
        let useCase = WorkspaceBrowserUseCase(store: store)
        _ = await useCase.start()
        await store.armBlockedAdd()
        var publishedRoots: [[WorkspaceRoot]] = []
        useCase.onStateChange = { state in
            if case .ready(let roots) = state { publishedRoots.append(roots) }
        }

        let add = Task { @MainActor in
            await useCase.addRoot(URL(fileURLWithPath: "/tmp/late", isDirectory: true))
        }
        await store.waitForBlockedAdd()
        useCase.suspendCommands()
        add.cancel()
        await store.releaseAdd()
        _ = await add.value

        #expect(useCase.roots.isEmpty)
        #expect(publishedRoots.allSatisfy { $0.isEmpty })
        #expect(await store.storedRoots().map(\.displayName) == ["late"])

        await useCase.resumeCommandsAndReconcile()
        #expect(useCase.roots.map(\.displayName) == ["late"])
        #expect(publishedRoots.last?.map(\.displayName) == ["late"])
    }

    @Test @MainActor
    func terminationDenialReloadDoesNotTurnCorruptStartupIntoReadyState() async {
        let useCase = WorkspaceBrowserUseCase(store: CorruptWorkspaceRootStore())
        #expect(await useCase.start() == .failed(.corruptStore("damaged")))
        #expect(!useCase.acceptsCommands)

        useCase.suspendCommands()
        await useCase.resumeCommandsAndReconcile()

        #expect(useCase.state == .failed(.corruptStore("damaged")))
        #expect(!useCase.acceptsCommands)
        #expect(useCase.roots.isEmpty)
    }
}
