# Large-file saving and recovery

Measured on an Apple Silicon Mac, macOS 26.5.1, September 17, 2026, with a release build. The initial fixture contains 1,502,284,069 UTF-8 bytes and 52,339,917 LF separators. The final probe copied the current input again (1,502,284,094 bytes; 52,339,918 LF separators). Each run independently verifies its own copied input. The probe copies its input into a temporary directory; it never edits the supplied file.

## Confirmed causes and changes

- Saving previously fetched a complete native text snapshot, normalized every Unicode scalar, and encoded the result on the main actor. Saving now captures immutable checkpoint bytes and revisioned deltas, then materializes and encodes them in a background task. Already-normalized UTF-8 keeps its existing byte buffer. Encoding, BOM, mixed line endings, conflict detection, atomic replacement, and save-point revision checks remain in effect.
- Recovery validation counted every byte to bound bookmarks, including documents without bookmarks. Empty bookmark/fold lists now need no line-count pass; necessary counts use a contiguous byte buffer.
- Each recovery commit previously reread the preceding archive. A store instance now uses its successful publication as a hint after checking on-disk generation ordering. Unknown/newer writers, collisions, and startup recovery still require complete validation. Every newly published archive is independently validated and durably written; previous blobs are never reused.
- Flush requests used to retain session metadata from before waiting for an older write, and unchanged termination rewrote all buffers. Ordinary queued requests now capture current metadata after admission. A matching durable session, change serial, and view state can satisfy a flush without rewriting. Explicit close-transaction candidates, changed carets, new edits, failed writes, and reset retain their distinct behavior.
- Initial native loads collected a document-sized undo insertion only to discard it. They now temporarily suspend undo collection; reloads preserving undo keep their previous behavior. Initial loads also reserve 64 KiB of editing space. Scintilla otherwise leaves an eight-byte gap, making the first few characters reallocate both the entire text and style buffers.

### Follow-up: actual save latency

The first patch still took 4.52 seconds to save. The follow-up removes redundant full-file work:

- Immutable editor checkpoints carry UTF-8 validation only when constructed from a Swift `String` or a validated delta materialization. Arbitrary checkpoint bytes and every delta still require validation. LF/CR fast paths use vectorized byte searches before deciding whether normalization is necessary.
- One owned file snapshot and bounded SHA-256 prefix states are cached. Reuse requires exact byte comparisons, including when inode, length, and mtime are unchanged. The public content token remains the same ordinary SHA-256. At most one snapshot of up to 2 GiB is retained; larger inputs use full hashing without retention.
- APFS saves clone into a private candidate, compare its bytes, and write only differing 1 MiB regions before syncing and atomic publication. Existing durability/conflict rollback remains in place. Sandboxed saves use Foundation's authorized replacement directory and replacement API. Unsupported cloning falls back to the existing atomic writer. The original is never patched in place.
- Explicit saves use user-initiated worker priority. The write payload is copied once into owned immutable bytes; the receipt hashes those committed bytes instead of rereading the entire path after publication. External modification checks still read the current file and verify its content before replacement.

## Release probe

```sh
swift run -c release DuckpadPerformanceBenchmark --large-file /path/to/large-file.txt
```

The probe uses a visible editor with word wrap enabled. It navigates to EOF, inserts Korean/emoji text and a newline in an explicit undo group, undoes it, types/undoes another 20 characters, saves after undo, appends Korean/emoji text and saves, undoes and saves again, compares each saved SHA-256, commits recovery, and verifies that termination persists a final unsaved edit. No document contents are printed.

| Operation | Initial patch | Follow-up |
| --- | ---: | ---: |
| Open and display | 8.56 s | 6.41 s |
| Navigate to EOF | 9.95 ms | 8.33 ms |
| First grouped insertion and undo | 56.09 ms | 5.36 ms |
| Another 20 characters and grouped undo | 6.06 ms total | 226.53 ms total |
| Atomic save after undo | 4.52 s | 1.46 s |
| Atomic save with appended Korean/emoji text | Not measured | 0.70 s |
| Atomic save after removing the appended text | Not measured | 0.77 s |
| Recovery commit | 3.21 s | 1.93 s |
| Unchanged termination recovery barrier | 0.12 ms | 0.09 ms |
| Termination barrier with a new unsaved edit | 3.36 s | 2.29 s |

These are individual local runs, not statistical latency guarantees or a measured comparison against Zed. The final typing batch had a 226 ms outlier; not every input latency is eliminated. The heartbeat can attribute a preceding synchronous operation's delayed tick to the following stage. Appended/truncated saves observed heartbeat gaps of 16.51/12.59 ms.

The actual sandboxed, packaged app saved a Korean/emoji append to a disposable 1.4 GiB document in **1.24 seconds**, with its normal recovery scheduling enabled. A separately streamed SHA-256 of the result matched the expected full document. An intermediate build measured 2.45 seconds before raising explicit save priority and removing the post-save reread. The standalone probe has recovery debounced for 60 seconds to separate stages; its figures should not be presented as identical to the app measurement.

Opening still installs the native document synchronously: the final probe observed a 4.27-second main-actor gap during initial loading. Recovery still writes full new generations, and cold caches, simultaneous recovery, non-APFS volumes, edits near the beginning of a file, and encoding conversions can take longer. These remaining costs are not described as instantaneous or eliminated.

## Regression checks

- Before the fix, tests reproduced duplicate unchanged flushes, stale queued recovery metadata, and a full native snapshot on save.
- 227 application/file-store/recovery-store tests passed after the final save changes, including encoding/BOM/line-ending combinations, UTF-8 delta boundaries, edits accepted during saving, queued recovery, reset, changed carets, generation collisions, corruption fallback, fault-injected durability failures, bookmarks, and verified directory handling.
- 49 native editor tests passed again with validated checkpoints. 30 isolated folding tests passed after the earlier load-path change. Native editor and folding suites are run separately because simultaneous AppKit suites can starve the existing two-second idle-folding deadline. A combined run hit that deadline; isolated folding passed without changing its timeout.
- The local preview combines this performance patch with the earlier uncommitted spacing, number input, plain-text indentation, Korean Enter, modification-marker, and line-number fixes in an ignored build source directory. Those earlier changes remain in their original worktree.

The packaged preview (0.6.3, build 41, native arm64, ad-hoc signed) opened the
same 1.4 GiB copy and completed its autosave. A normal application Quit then
exited the actual process in 0.36 seconds; no forced termination was used.
Package verification and Finder/open, bookmark save/relaunch, layout, and
sandboxed XPC smoke checks passed. Native save-panel automation was skipped.
The first smoke invocation exited without a retained diagnostic; a rerun with
preserved logs passed all assertions.

The follow-up adds APFS candidate/source isolation checks, append/middle-edit/truncate byte equality in both coordinated and ordinary saves, full-SHA reference checks, same-inode/same-size/exact-restored-mtime conflict detection, and fault-injected clone-save durability checks. The final preview also preserves the earlier editor UI changes.

To exercise a real sandboxed large save, open a disposable `Duckpad-Large-Save-Smoke.txt` with Launch Services and set `DUCKPAD_SECURITY_SCOPE_SMOKE_NAMESPACE` to a fresh test namespace and `DUCKPAD_LARGE_FILE_SAVE_SMOKE` to its absolute path. The probe waits for the bookmarked open, appends text, measures `saveActive`, verifies the full expected SHA-256, resets only its isolated recovery session, and exits. Never point this probe at a user document.

Final preview v4 (0.6.3, build 41, native arm64, ad-hoc signed) passed package verification and the standard app smoke script again. Finder/bookmark save/relaunch, layout, and sandboxed XPC checks passed; native save-panel UI automation remained skipped. This is a local test build, not a notarized release.
