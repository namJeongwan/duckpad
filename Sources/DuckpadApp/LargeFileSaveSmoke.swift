import CryptoKit
import Darwin
import DuckpadApplication
import DuckpadEditorAdapter
import Foundation

/// Opt-in probe for the real sandbox/Powerbox save path. Run only on a disposable
/// fixture opened through Launch Services in a dedicated smoke namespace.
@MainActor
enum LargeFileSaveSmoke {
    static func run(path: String, workspace: ScratchWorkspaceUseCase, editor: ScintillaEditorAdapter,
                    files: FileDocumentUseCase, recovery: SessionRecoveryUseCase) async {
        do {
            let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
            precondition(url.lastPathComponent == "Duckpad-Large-Save-Smoke.txt")
            for _ in 0..<3_000 {
                if workspace.activeFileContext()?.binding?.canonicalPath == url.path { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard workspace.activeFileContext()?.binding?.canonicalPath == url.path,
                  workspace.activeFileContext()?.binding?.securityScopedBookmark != nil,
                  let view = editor.activeScintillaView else { throw ProbeFailure.failed("bookmarked open") }
            let suffix = Data("저장 성능🦆\n".utf8)
            let expected = try await digest(url, appending: suffix)
            view.setPrimarySelectionUTF8Range(NSRange(location: Int(view.documentByteLength), length: 0))
            view.beginGroupedUndo()
            view.insertCommittedText(String(decoding: suffix, as: UTF8.self))
            view.endGroupedUndo()
            let start = ContinuousClock.now
            guard case .saved = await files.saveActive() else { throw ProbeFailure.failed("save") }
            let elapsed = start.duration(to: .now)
            print("LARGE_SAVE_SANDBOX seconds=\(Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18)")
            fflush(stdout)
            guard try await digest(url) == expected else { throw ProbeFailure.failed("saved bytes") }
            // Checkpoint recovery is also isolated; never restore this test session
            // into the user's ordinary session after the probe exits.
            guard case .saved = await recovery.reset() else { throw ProbeFailure.failed("recovery reset") }
            await files.releaseAllSecurityScopedAccess()
            print("LARGE_SAVE_SANDBOX verified=true")
            fflush(stdout)
            Darwin._exit(0)
        } catch {
            FileHandle.standardError.write(Data("Large save smoke failed: \(error)\n".utf8))
            Darwin._exit(87)
        }
    }

    private enum ProbeFailure: Error { case failed(String) }

    private static func digest(_ url: URL, appending suffix: Data = Data()) async throws -> SHA256.Digest {
        try await Task.detached {
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var hash = SHA256()
            while let bytes = try file.read(upToCount: 8 * 1_024 * 1_024), !bytes.isEmpty { hash.update(data: bytes) }
            hash.update(data: suffix)
            return hash.finalize()
        }.value
    }
}
