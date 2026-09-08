# Scintilla 5.6.6 integration

> Status: Phase 2 foundation implemented; review pending  
> Product baseline: macOS 13, Swift 6, AppKit, SwiftPM

## Outcome

Duckpad production composition now uses the official Scintilla Cocoa editor.
`NSTextView` remains available only as the Phase 1 test/fallback adapter. The
Notepad++ reference checkout is neither a source nor a build input.

The dependency direction is:

```text
DuckpadApp
├── DuckpadPresentation
├── DuckpadInfrastructure
└── DuckpadEditorAdapter (Swift, @MainActor, EditorPort)
    ├── DuckpadApplication -> DuckpadDomain
    └── DuckpadScintillaBridge (Objective-C++/C++17)
        └── Vendor/Scintilla/5.6.6
```

Presentation receives an `EditorPort` and an opaque `NSView`. It does not import
the bridge. Application ranges are UTF-8 byte offsets; Cocoa's UTF-16 ranges are
converted inside the fallback adapter. Scintilla is the live-text authority,
while Domain continues to own only `BufferID`, revision, and dirty metadata.

## Provenance and licensing

- Official archive: `https://www.scintilla.org/scintilla566.tgz`
- Version: `5.6.6`; archive `version.txt` value: `566`
- SHA-256: `b6b08598c68fac90990d010c1142494d707530602b5320753274d045c2b02189`
- License: [`Vendor/Scintilla/5.6.6/License.txt`](../../Vendor/Scintilla/5.6.6/License.txt)
- Local provenance receipt: [`PROVENANCE.md`](../../Vendor/Scintilla/5.6.6/PROVENANCE.md)
- Reproduction helper: [`vendor_scintilla_5_6_6.sh`](../../scripts/vendor_scintilla_5_6_6.sh)

The helper downloads to a temporary directory, fails on a digest mismatch,
refuses to overwrite its destination, and copies the same 105-file upstream
subset used here. It omits upstream README/build/test material and all
Notepad++ files. A clean reproduction had the exact same path inventory.

There is one documented upstream-source patch: the two cursor lookups in
`cocoa/ScintillaView.mm` resolve the official PNG files through Duckpad's SwiftPM
resource bundle instead of looking for Xcode-generated TIFFs. Original file
SHA-256 is `40e21596ab0939e9be4bae426325b6cac4db88da26fd7d72008a611921cf191b`;
patched SHA-256 is
`d23aedf27b6adfacb1d2b6607eacb5eed354b1f6529c407a1dea6501848f2420`.
The four packaged cursor PNGs are byte-identical to the official archive.

## Bridge boundary

[`DuckpadScintillaBridge.h`](../../Vendor/Scintilla/5.6.6/bridge/include/DuckpadScintillaBridge.h)
is the only public Clang header. Its façade exposes:

- creation and an AppKit view;
- owned UTF-8 snapshots;
- stale/overflow/range/UTF-8 code-point-boundary checked incremental replacement;
- copied immutable inserted/deleted UTF-8 payload notifications with base/result revision and origin;
- focus, input enablement, accessibility identifier, word wrap;
- primary/multiple selections, copy/paste, undo/redo;
- marked-text update/unmark operations for Cocoa IME.

`ScintillaView`, `SCNotification`, `SCI_*`, raw pointers, document handles, and
C++ types remain private to the `.mm` implementation. The notification bridge
copies borrowed Scintilla bytes before returning and advances one revision for
each actual insert/delete notification. One committed multi-code-point input may
therefore produce multiple consecutive revisions; this is intentional.

Start and end offsets are normalized with Scintilla's `POSITIONBEFORE` and
`POSITIONAFTER` character-boundary APIs before any target replacement. A split
inside a 2/3/4-byte scalar is a typed failure and cannot change text or revision.
Loading or reaching `UInt64.max` makes the native view read-only before another
committed input, paste, undo/redo, or IME mutation; attempted façade mutations
publish `DPScintillaErrorRevisionOverflow` without a notification or visible
unpersisted change.

The Swift adapter owns one Scintilla child view per open `BufferID`. Switching
tabs keeps each buffer's text and undo stack. Retirement removes only the closed
buffer after Application reports a successfully persisted close. Revision
divergence restores the explicit checkpoint plus its bounded accepted-delta
journal. Accepted keystrokes append only the inserted/deleted delta; they never
read or decode the full document. Full snapshots occur only on explicit
snapshot/save, activation, initial load, and rejection recovery.

## Fold-state recovery boundary

Phase 31 keeps folding inside the existing Scintilla/Lexilla boundary. The
Duckpad-owned bridge exposes typed capability queries, current/all commands,
bounded contracted-header capture, restore, and coalesced post-idle recovery
progress. It uses Scintilla's fold levels and `SCI_CONTRACTEDFOLDNEXT`; it does
not add a parser, language server, background worker, or dependency. Automatic
fold-change handling remains enabled so editing away a header cannot strand
hidden descendants, without expanding the modification event mask.

Each shared-document pane owns its own canonical `FoldRecoveryState`: sorted,
unique, nonnegative, and capped at 10,000 header lines. The adapter tracks
pending idle-style recovery by native view identity, captures native contracted
headers union pending headers, and restores primary and secondary state
independently. Accepted text mutations invalidate both panes' stale pending fold
state; rejected mutations retain and reapply the authoritative recovery state.
Plain Text and documents above the language style budget stay editable with all
folds expanded and folding commands disabled. Failed lexer application retains
the prior language, capabilities, and fold state.

Gutter, menu, keyboard, Command Palette, and recovery operations share the same
typed façade. Changed user operations publish one fold-state callback; no-ops
and restore publish none. Tests and the production smoke verify that these
operations preserve UTF-8 bytes, revision, dirty state, full selection, Undo,
and Redo. Terminal adapter teardown clears native callbacks and pending view
identities.

## Block comments and indentation boundary

Phase 32 keeps language-aware editing inside the existing narrow bridge. A
successfully applied `EditorLanguageConfiguration.comments` value is the sole
block-comment authority. The manifest accepts a block pair only when it has
exactly two nonempty delimiters and each is at most 64 UTF-8 bytes. The native
command treats both delimiters literally and accepts exactly one stream
selection with no virtual space; multiple, rectangular, line, thin, and virtual
selections are no-ops.

The focused primary or secondary view owns selection, while the primary view
remains the only shared-document publisher. A block toggle performs one target
replacement and publishes one aggregate edit/revision after suppressing the
native component notifications. UTF-8/CRLF bytes, selection direction,
rejection recovery, dirty state, and exact Undo/Redo are preserved. The Edit
menu and Command Palette expose the same accessible Toggle Block Comment action
at `⌥⌘/`; core shortcut identity wins over colliding extension declarations.

Direct keyboard input of `}`, `]`, or `)` dedents one configured indentation
level only when the current-line prefix is indentation-only. Inspection is
capped at 4,096 bytes. Paste, IME composition/commit, programmatic mutation,
multi-character input, non-stream or virtual selection, a non-whitespace
prefix, and over-bound lines retain literal input without auto-dedent. The
bridge reserves five revision slots: two forward aggregate edits plus three
worst-case grouped-Undo components. If fewer remain, only the existing literal
closer path runs. The initiating view owns pending input and teardown, while the
primary publisher remains authoritative; rejected components recover exactly
the accepted prefix. Pending direct input snapshots both primary and split-pane
view states before native insertion, so a rejected closer restores the
input-time caret and anchor in the initiating pane and preserves the peer
pane's independent selection.

Explicit Indent Line(s) and Unindent Line(s) continue to use Scintilla's native
Tab/Backtab commands. Phase 32 tests prove the applied two-space, four-space,
and Makefile tab configurations for single/multiline selections, mixed leading
whitespace, grouped Undo, and revision/recovery publication. No parser, LSP,
background worker, editing framework, or dependency was added.

## Production composition and tests

[`DuckpadMain.swift`](../../Sources/DuckpadApp/DuckpadMain.swift) constructs
`ScintillaEditorAdapter` and injects its host view into
`DuckpadWindowController`. The controller still defaults to
`TextViewEditorAdapter` only for isolated Phase 1 tests/fallback construction.

[`ScintillaEditorAdapterTests.swift`](../../Tests/DuckpadEditorAdapterTests/ScintillaEditorAdapterTests.swift)
uses real hosted AppKit/Scintilla views and covers:

- UTF-8 incremental replacement and stale-revision rejection;
- split start/end rejection for 2/3/4-byte scalars and combining marks in debug/release;
- revision-exhausted committed text, paste, undo/redo, IME, and external apply;
- Hangul/emoji snapshots and large UTF-8 content;
- Cocoa marked-text update/commit, copy, paste, undo, redo;
- multiple selections and word-wrap toggling;
- exact notification revision chains and Swift `EditorPort` publication;
- per-buffer undo isolation and retirement;
- actual controller hosting/focus and cursor resource decoding;
- a public-header guard against raw Scintilla surface exposure.
- instrumented 1/10/50 MB accepted edits: zero snapshot reads, one notification,
  and one copied payload byte, with a bounded latency guard.

## Verification

Commands used from the repository root:

```sh
swift build
swift test
swift test -c release
swift test --scratch-path /tmp/duckpad-scintilla-fresh-final
swift build -c release
swift build -c release --triple x86_64-apple-macosx13.0 \
  --scratch-path /tmp/duckpad-scintilla-x86-build
DUCKPAD_SMOKE_EXIT=1 swift run --skip-build DuckpadApp
```

Observed on 2026-09-02 after the focused P2-01..P2-03 remediation: arm64
debug/release build and link pass; 46/46 tests pass in debug, release, and a
fresh scratch build. The smoke app prints
`Duckpad smoke window ready with Scintilla 5.6.6` after asserting the production
view exists. Both arm64 and cross-compiled x86_64 release executables report
`minos 13.0`; the latter is a Mach-O x86_64 executable. Intel runtime remains
a CI/hardware gate. Four upstream macOS 12 deprecation warnings remain
non-blocking follow-up work. Lexilla, syntax styling, exhaustive VoiceOver/manual
candidate-window validation, and packaged signed `.app` distribution are later
Phase 2 slices.

Phase 32 validation on 2026-09-05:

- Debug and Release builds exit 0. Every requested focused Debug and Release
  filter exits 0. Counted summaries are 8/8 manifest, 8/8 workspace, 66/66 tab
  flow, 5/5 extension, and 7/7 Command Palette tests in both configurations.
  The aggregate language/Scintilla filters retain the known console truncation;
  complete independently reviewed named batches pass 15/15 block-comment and
  the original 18/18 closer/indent tests in both Debug and Release. Final-review
  remediation adds a separate 3/3 rejected-selection recovery proof rather than
  changing the original 18/18 count; related lifecycle tests pass 9/9 and the
  Language split gate passes 56/56 in both configurations.
- The first final-range candidate exposed one Important recovery gap: bytes and
  revision were authoritative after a rejected closer, but view state could be
  stale. RED observed primary caret/anchor `11/11`, reverse selection `2/5`, and
  focused-secondary `11/11`, each incorrectly restoring as `0/0`. Remediation
  `2aa8754` snapshots both panes when pending direct input opens; the 3/3, 9/9,
  and 56/56 gates above are green. Final re-review and push remain pending.
- The real Release AppKit language smoke exits 0 after exact UTF-8/CRLF Swift
  block wrap, one accepted aggregate revision, exact Undo/Redo, JSON one-level
  direct-closer dedent with one grouped Undo, and the retained highlighting,
  folding, Python-switch, palette, text, and revision checks.
- The frozen schema-1 performance runner reports exactly six passes on Mac16,7:
  warm launch 289.016 ms, typing p95 0.017792 ms, 100 MiB open 902.360833 ms,
  200-tab reflow p95 0.001875 ms, folder search 263.726791 ms, and 10,000-header
  fold recovery 114.223042 ms. The focused Release 1 MiB block toggle passes
  its 250 ms internal assertion; the complete test reports 0.154 seconds.
- Monolithic `swift test` and `swift test -c release` are not passes: both exit
  1 with SwiftPM testing-helper `unexpected signal code 11` after 5.03 and 5.10
  seconds. Isolated checkouts of parent `4510f3a` reproduce the same signal with
  the exact commands after 58.61 and 217.42 seconds. No extension-host timeout
  or new Phase 32 assertion failure appeared, so this remains the known
  process-global AppKit baseline blocker.

## Agent Work Log

| Date | Agent/work | Evidence |
| --- | --- | --- |
| 2026-09-02 | Clean investigation established official standalone 5.6.6, digest, Cocoa Xcode source allowlist, C++17/AppKit/QuartzCore requirements, UTF-8/IME/accessibility constraints, and arm64/x86_64 spike feasibility. | Decision merged into this document; investigation used temporary directories and did not copy from or modify the reference checkout. |
| 2026-09-02 | `/root/philosophy_parity` used the implementation workflow to vendor the official subset and build the Objective-C++ façade, Swift adapter, production injection, resources, and tests. | `swift build`; 42/42 debug, release, and fresh-scratch tests pass; no staging or commit performed. |
| 2026-09-02 | Re-ran acquisition into a new temporary destination. | Archive digest matched; 105 upstream paths matched; only the one recorded cursor lookup patch differs byte-for-byte in the repository. |
| 2026-09-02 | Built both supported architecture targets and launched the development executable. | arm64 run pass; x86_64 cross-link pass; Intel runtime not claimed. |
| 2026-09-02 | `/root/philosophy_parity` addressed review evidence P2-01..P2-03 without changing the review verdict. | Added character-boundary preflight, pre-mutation revision-exhaustion read-only/error behavior, inserted/deleted payloads, snapshot/notification instrumentation, and a bounded accepted-delta journal. 46/46 debug, release, and fresh tests pass; 1/10/50 MB cases record zero snapshots and one-byte incremental work. |
| 2026-09-04 | Phase 31 fold-state recovery and controls | Typed Scintilla folding, pane-specific bounded recovery, native menu/VoiceOver/Command Palette routing, Debug/Release focused validation, and production Swift folding smoke pass. The six-budget Release gate measured exact 10,000-header contract/capture/shared-pane restore at 129.29475 ms (250 ms maximum). Monolithic Debug/Release signal 11 was reproduced at Phase 30 parent `0e511bf` and is not reported as passing. |
| 2026-09-05 | Phase 32 block comments, indentation, and hover correction | Literal single-stream block toggle, bounded five-revision direct-closer dedent, input-time two-pane selection recovery, configured native indent/outdent proof, accessible `⌥⌘/`, and strip-owned single-hover state. Focused Debug/Release gates, six performance budgets, 1 MiB stress, and real AppKit smoke pass; monolithic signal 11 reproduces at parent `4510f3a`. Final re-review and push remain pending. |
