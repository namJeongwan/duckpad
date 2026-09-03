# Phase 20 — Saved Workspace File Browser

Status: **Implemented; review pending**

## Outcome

Duckpad now keeps user-selected folders in a native workspace sidebar. **File → Add Folder to Workspace…** (`Command-Control-O`) adds a root, and **View → Workspace Sidebar** (`Command-Shift-E`) shows or hides the browser. A directory dropped onto the window or sidebar is added as a root; a file drop continues through the ordinary file-open path.

The outline loads one directory level at a time, places folders before files, and preserves expanded folders and selection independently for every root. Double-click or Return opens files through the existing `FileDocumentUseCase`; the same inputs toggle directories. The contextual menu reveals any loaded item in Finder or removes its containing root. Missing bookmark targets remain visible as unavailable roots so users can remove or re-add them deliberately.

## Architecture and persistence

- Domain adds only the stable `WorkspaceRootID` value type.
- Application owns typed root/entry/state models and `WorkspaceRootStore`; it publishes loading, ready, and explicit failure states without importing AppKit or filesystem code.
- Infrastructure stores schema-v1 security-scoped bookmarks and bounded navigation metadata in `Application Support/Duckpad/workspace-roots.json`. `DUCKPAD_WORKSPACE_ROOTS_FILE` redirects only this archive for controlled tests and smoke runs.
- Presentation owns `NSOutlineView`, split-view layout, native menu and panel commands, drag/drop, Finder activation, lazy-load task admission, and root-specific debounced navigation writes.

The browser never creates a second document-opening authority. Infrastructure opens the selected root and each relative component descriptor-relatively, reads the final regular-file descriptor, and returns its bytes plus `FileIdentity` as one immutable `WorkspaceFileRead`. `FileDocumentUseCase` consumes that payload directly without reopening the path, then enters the same decoding, tab deduplication, revision, recovery, and failure paths as **Open…**.

## Bounds and filesystem safety

The persisted archive is capped at 1 MiB, root count at 32, expanded paths at 1,000 per root, raw immediate directory entries at 10,000, an opened file at 1 GiB, and each relative path at 16 KiB. Archive loading itself uses a no-follow regular-file descriptor, reads at most the limit plus one byte, and rejects identity/size changes during the read. The store validates schema, unique root IDs, absolute last-known roots, unique saved and resolved paths, display names, navigation paths, and bookmark targets on every initial load. Corrupt input stays failed on retry instead of silently replacing the user's saved list.

Enumeration uses descriptor-relative `readdir`/`fstatat`, counts raw names before filtering, checks cancellation during scanning, and stops at the 10,001st entry before further materialization. It skips dot/Finder-hidden entries, packages, symbolic links, and non-regular files. Relative paths reject absolute paths, empty components, `.`/`..`, NUL, and excessive length. Root device/inode identity must remain stable, and every directory/file component is opened with `openat`, `O_NOFOLLOW`, and the required file type. Final bytes and metadata come from the same descriptor and must remain unchanged across the bounded read, preventing intermediate or last-component swaps from escaping the root. Workspace state writes are atomic; the parent directory is mode `0700` and the archive is mode `0600`.

For restored bookmarks, security-scoped access is attempted before canonicalization, metadata inspection, or bookmark refresh. A failed acquisition is published as unavailable when the process is sandboxed; successful access is retained on the exact resolved URL and balanced when the root is removed or the application-lifetime store is destroyed. This permits lazy navigation and later file opens without presenting another panel.

## Lifecycle and UI behavior

Browser mutations are synchronously admitted only after both document restore and root-bookmark restore are ready and while termination review is inactive. Root-list and navigation mutations share one FIFO serialization gate, preventing actor reentrancy from publishing stale state after concurrent Add operations. A generation token is rechecked after every awaited store mutation: termination or window close suppresses late publication even when a store ignores cancellation, while a denied termination always reloads durable store state before commands resume. That reload preserves corrupt/unavailable failure instead of manufacturing an empty ready state. Lazy-load, add, remove, panel, and navigation tasks remain cancellable and detachable. Once a prepared workspace file read is accepted for document opening, it moves to a separate mutation task that termination must join before final recovery flush; this prevents a cancellation-ignoring session commit from adding a tab after the final archive is written. Native file panels are explicitly cancelled, and a weak window reference prevents even a cancellation-ignoring presenter from retaining a closed controller/window.

Expansion writes are revisioned per root, so rapid changes in one root cannot cancel another root's navigation state. Restoration loads saved paths shallowest-first without recursively enumerating unrelated folders. A per-directory load failure leaves the rest of the outline usable, marks the affected row, and permits collapse/re-expand retry; a store-level startup failure remains an explicit unavailable state.

## Validation

Application tests cover typed state publication, serialized concurrent Add, late cancellation-ignoring mutation suppression and resume reconciliation, corrupt-start failure preservation after termination denial, prepared descriptor-read opening without a second store/path read, add/remove/navigation behavior, duplicate and root limits, and rejection of directory/foreign-root file resolution. Infrastructure tests cover security bookmark persistence, access-before-inspection ordering and exact stop balancing, sandbox-required acquisition failure, deterministic folder-first enumeration, hidden/package/symlink exclusion, navigation round trip, traversal and intermediate-symlink escape rejection, a last-component file-to-symlink swap, raw-entry bounds and cancellation, forged entry kinds, and repeatable corrupt-archive failure. AppKit tests cover immediate termination during a blocked accepted workspace-file session commit, delayed root-restore admission, cancellation-ignoring panel termination and controller/window deallocation, initial lazy loading, expansion publication, Return-key file activation, Finder/remove context routing, exact menu selectors and shortcuts, global shortcut uniqueness, and sidebar split visibility.

Exact-current full Debug and Release suites each pass 288/288. A production executable smoke with isolated recovery/workspace archives persists a real folder, resolves its root in the native sidebar, and lazily enumerates `smoke.txt`; `git diff --check` passes.

README files and the ignored Notepad++ reference are outside this work. The pre-existing user edits in `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` remain preserved and excluded.

## Next slice

Native multiple-window lifecycle follows. Macro recording/playback remains excluded.
