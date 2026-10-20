# Search experience review — 2026-10-20

Branch: `feature/search-experience`, based on main `684c22f`. Release preparation targets 0.14.0 (62). The final signed candidate includes the implementation, version defaults and release notes; publication follows independent review and integration through a PR.

## Behavior

- Cmd-F and Cmd-H keep the existing Notepad++ style Find/Replace dialog, including its Find/Replace/Find in Files/Bookmarks tabs and appearance options.
- Cmd-Shift-F and Cmd-Shift-R open a separate project-search window. It has compact one-line match rows with filename/line on the right, above a resizable code-context preview with logical line numbers and exact match highlighting. Normal, Extended and Regex use the existing search engine and options. Project search now defaults to All; the four scopes and their buffer/disk precedence are described in the final follow-up below. Folder retains its own Browse selection.
- Two complete, unmodified Shift taps open a filename/path search window. Shift typing, other keys/modifiers, mouse input, inactive host windows, sheets and IME marked text disarm the gesture. A Search Files menu command is also available.
- Filename search shows open tabs immediately. Workspace names are enumerated asynchronously through existing root access and symlink checks, without reading contents. Enumeration is limited to 20,000 entries, 16 MiB of aggregate path bytes and 128 directory levels; the UI reports truncation and skipped folders. Larger name filters run off the main actor. Results are capped at 100 rows, with filename matches ranked ahead of path-only matches.
- Both new windows share panel chrome and selection drawing; filename rows show name/path while content matches use dense one-line rows, and inherit the invoking window's appearance. Esc closes the active search window from the query field, table or preview; Enter in result tables opens the selected result. Classic Find is dismissed when opening either new window.

Both popups dismiss on an outside mouse click without consuming that click or forcing editor focus. Popup controls, attached sheets, and native menu tracking are excluded; losing application activation also dismisses the popup unless a sheet is attached. Context previews are read-only, limited to 32 KiB around the match, and loaded off the main actor from captures/files no larger than 8 MiB. Folder previews recheck the searched file identity and never open an editor tab or write a file.

The reference-layout follow-up replaces native search-cell decorations with independent 18 pt icons and editable 28 pt text fields. Find → Tab moves directly into Replace with; Shift-Tab returns to Find. Search options remain separate from text editing. A filename mask checkbox/field supports comma/semicolon lists, * and ? wildcards, and ! exclusions. Folder enumeration filters before file reads and file/byte budgets, and open-document search filters before captures. Moving results into the classic Find window retains and visibly displays the mask; all subsequent searches and replacements keep that mask until it is explicitly cleared. Mask checks occur after asynchronous persistence/generation boundaries at the actual capture point.

The preview has an opaque 40 pt file header over the code surface, and clips its ruler inside the code area. A separate 54 pt footer contains 32 pt Open in Find Window, Replace All and Replace controls. The current design uses Duckpad's actual open-document/folder scopes; it does not add inactive JetBrains module controls or pretend to support a separate search-results tab.

The shared-input follow-up replaces duplicated field setup with `SearchInputField` and `SearchInputCell` across content Find/Replace, filename mask, filename search and the command palette. The component owns flat chrome, a 28 pt default height, typography and a centered line rect. Rendering, text selection and the native field editor use that same rect. Each field retains an independent undo-capable editor. File masks use a subtle 1 pt underline instead of native bezel/background/focus glow; no extra search glyph is drawn inside any field.

The alignment regression failed on the previous source (`/tmp/duckpad-search-input-before.log`): Find/Replace were 26 pt with full-height drawing rects, while mask kept native bezel and focus ring. The fix passed the real field-editor alignment checks and all 35 related presentation functions (`/tmp/duckpad-search-input-final.log`, SearchExperienceTests, CommandPalette and SearchPopupDismissalTests). Forty snapshots include all eight languages in light/dark, empty inputs and separate focused Find/Replace/mask states. Focused Korean/Latin content and mask chrome were visually inspected. This follow-up did not rerun the earlier 332-function broad set because application, domain and file operations were unchanged. Actual IME marked-text → commit → Undo was not newly exercised; the existing field-editor ownership/input model was preserved.

## Filename reference and option-state follow-up

Double Shift now has a Files / Open Documents header, shared flat query field, 28 pt one-line rows with material file icons, highlighted filename terms, directory and workspace name, plus a selected full-path footer. The Open in Right Split action is available when the host supports editor groups. It copies the existing buffer into a new pane beside the invoking pane, preserving the source selection and unsaved contents. Inactive tabs, unopened workspace files, and files already visible in another pane use the same path. Workspace files pass existing root/identity validation and inactive document preparation before placement. No new file is saved. Filename/path scope is unchanged; no inactive Classes/Symbols/Actions controls are added.

`SearchOptionButton` owns persistent `isOn` state and one action for native mouse target/action, keyboard, programmatic and accessibility activation. Cc/W/regex/dot-newline controls show a persistent accent tint and expose checkbox values. Tests use the real matcher to verify counts in both directions, regex/dot-newline semantics, and rendered on/off pixels. These tests pass in `/tmp/duckpad-search-options-functional.log` and the final focused run.

Filename normal/split requests share cancellation and generation ownership. Both prepare workspace targets without activation, then either place the split or call `ScratchWorkspaceUseCase.activateIfCurrent`, which checks cancellation and the request after acquiring the workspace transaction. Review identified source-pane replacement, old deferred requests overriding newer choices, and queued activation after cancellation. The previous behaviors failed regression runs (`/tmp/duckpad-filename-split-before.log`, `/tmp/duckpad-search-queued-before.log`). The final focused run (`/tmp/duckpad-search-options-final.log`) has terminal PASS for 47 functions in seven suites, including both deferred request directions, inactive/unopened/other-pane split targets, queued navigation, popup dismissal and command palette regressions.

Filename minimum-width layout checks cover every locale. An additional sixteen dense filename-reference captures bring `.build/search-options-snapshots` to 56 light/dark/input captures; English dark and Korean light filename captures were visually inspected. All eight catalogs pass 1,176 strings and four plural entries. A packaged test instance was opened in an isolated recovery namespace, but the Mac was at the login screen, so actual mouse/keyboard interaction could not be verified. Accessibility activation and native rendered-state tests are automated evidence, not a substitute for that manual check. The earlier broad 332-function set was not rerun for this presentation/navigation follow-up. Actual IME commit/Undo remains unexercised in this follow-up.

## Replacement safety

Open-document replacement uses the earlier `feature/open-documents-replace` implementation, carried forward without changing or deleting its original worktree. Matching uses immutable captures and bounded off-main planning. Each changed document is one native Undo group. No-op replacements do not create dirty state or Undo entries. Read-only, IME-composing, changed, closed, unavailable, timed-out, cancelled and over-budget targets are reported.

Replace All requires a completed, nontruncated search result and explicit confirmation. The separate Replace button applies only the selected match range; both paths preserve revision/identity checks and per-document Undo. Revision checks reject open documents edited after that result. Folder targets are opened into inactive, normal recoverable editor buffers after validating the searched file identity; preexisting dirty documents are skipped. Native backing views are created lazily when applying a bounded plan. Existing active tabs, selections and focus stay unchanged. No source file is written automatically. Save / Save All remains an explicit user action; Undo is per document, not a transaction across all files.

Folder replacement prepares at most 200 files per operation and reports the remainder as over-limit. Cancelling before application leaves prepared files unmodified; cancelling during application retains and reports completed edits. Closed targets remain represented in both normal and cancelled summaries.

## Validation

332 distinct related test functions passed across the final broad run (331) and the isolated popup suite (four, including the remaining real-sheet test). The real-sheet case is isolated because an earlier broad screenshot run exited its presentation test process during that case without a terminal suite result, despite SwiftPM returning zero; that earlier run is not counted as a complete pass.

Commands and logs:

- `DUCKPAD_SEARCH_SNAPSHOTS="$PWD/.build/search-reference-snapshots" swift test --no-parallel --skip clicksInsideThePopupOrItsSheetDoNotDismissIt --filter 'Search|OpenDocuments|FolderDocuments|FileDocument|FileFormat|FileOpening|WorkspaceBrowser|WorkspaceFileName|Legacy|Encoding|Recovery|ScratchSession|EditorGroupCommand|NativeFile|TabNavigation|ShortcutRegistry'` — `/tmp/duckpad-search-reference-verified.log`, 331 functions passed: 97 presentation, 42 infrastructure, 85 editor, 14 domain, 93 application. All targets emitted terminal PASS.
- `swift test --no-parallel --filter SearchPopupDismissalTests` — `/tmp/duckpad-search-reference-dismissal.log`, four functions, including the real attached-sheet case and first-click editor delivery for both popups.
- The final screenshot run generated 34 new-window snapshots: both windows, eight languages, light/dark, plus empty Find/Replace input in light/dark. Empty English, populated English/Korean/German and filename Portuguese were visually inspected. Input layout checks cover all locales at the minimum width.
- `python3 scripts/verify_localizations.py` — 1,175 strings and four plural entries in all eight languages, including literal lookup and format validation.
- `git diff --check` — passed.

The original icon/field/Tab/footer regression tests failed on the prior layout (`/tmp/duckpad-search-reference-before.log`), then passed on the rebuilt fields. Native tests verify regex capture replacement for a selected match, zero-length insertion at one selected match, independent Undo/Redo, and masked search → classic Replace All with both .swift and .txt buffers while disk stays unchanged. A blocked-persistence/tab-switch regression failed before the capture-boundary fix: both Replace All and Replace modified the excluded .txt file and marked it dirty (`/tmp/duckpad-mask-switch-before.log`). Both cases pass after the fix (`/tmp/duckpad-search-reference-final-focused.log`). File-mask enumeration tests ensure excluded files consume neither read bytes nor matching-file limits, including Unicode, exclusions and literal * in a filename.

The compact Cc/W/.n control regression also failed before its earlier fix: checkbox-style cells required 36–40 pt but were constrained to 28 pt. Separate text toggles now pass minimum-width layout checks in all locales/modes. Menu tracking is tested using AppKit tracking notifications; actual native menu mouse selection is not automated.

An earlier broad run exposed an obsolete classic-window routing test and an idle fold-recovery timing failure during parallel UI work. The routing test now exercises the requested new window. The fold test passed individually, and the subsequent complete related run with `--no-parallel` passed without changing its assertions or timeout. The native regression for newly opened inactive files failed before backing-view preparation was corrected, then passed with exact disk-byte, caret, dirty-state and Undo/Redo checks. The old folder-routing test was updated to drive the new project-search window, while retaining identity and UTF-8 selection assertions.

All eight language catalogs include the new strings. UI layout checks and screenshots cover both new windows in all eight languages, in light and dark appearances. Korean, German and Brazilian Portuguese screenshots were visually inspected. Search close/query-generation tests reject late results, and native menu dispatch exercises Esc from five distinct focus locations.

## Limits

The lower preview shows bounded surrounding code with line numbers, not a full-file before/after replacement diff. Result-list gold highlighting currently covers literal Normal-mode matches; Regex/Extended rows do not have gold highlighting, and Whole word may highlight additional literal substrings in the row. When bounded context can be loaded, the lower code preview uses the exact match range for all modes. If the source exceeds 8 MiB, changes, or cannot be read, the original result snippet remains; that fallback does not provide exact-range highlighting for Regex/Extended. Closing during replacement cancels remaining work and discards the popup summary; already-applied unsaved edits and per-document Undo remain available in editor tabs. Folder content search retains the existing UTF/BOM decoder, including its skip behavior for unsupported legacy byte encodings; explicit legacy decoding for folder search is still deferred. Hidden files, packages and symbolic links follow the existing workspace/folder enumeration exclusions. This work does not add macros, marked-line deletion, whitespace preferences, mouse-wheel zoom, indexing of every file on the Mac, or LSP symbol search.

A native Apple Silicon app including the shared-input follow-up was packaged at `build/search-inputs/Duckpad.app` and passed `scripts/verify_macos_app.sh` (resources, helper isolation and signatures). The previous task app was closed normally and this latest build was launched. Packaging verification for the shared-input build is recorded in `/tmp/duckpad-search-input-app-verify.log`. This is an ad-hoc signed local build; a universal release build, Intel hardware execution and notarization have not been performed for this source change.

## Independent review outcome

The independent reviewer approved the final source changes, including the preview redesign, outside-click handling, menu tracking and option-cell fix, with no remaining Blocker/Major findings. The two remaining highlighting/closed-summary Minor limitations are recorded above. Follow-up reviews also found and resolved mask loss during classic-window handoff, asynchronous tab-switch mask bypass, and wildcard-star matching of filenames containing a literal star. The final source revision, including bounded preview clipping, was approved. The last minor Browse-cancellation issue was fixed and reviewed again. Its focused regression was also executed against the previous behavior: it failed the button-enabled assertion (`/tmp/duckpad-search-browse-before.log`), then the restored final source passed all eleven UI functions (`/tmp/duckpad-search-layout-final.log`). No hooks, trust settings or user worktrees were modified, and no commit or push was performed.

The filename/option follow-up received independent final approval with no remaining Blocker/Major findings after the inactive preparation and queued-navigation fixes. Its final native Apple Silicon bundle is `build/search-files-final/Duckpad.app`; `/tmp/duckpad-search-files-app-verify.log` records successful resource, helper-isolation and signature verification. The prior local task app was quit normally, and this exact final bundle was launched. The isolated UI-test instance was also quit normally. No commit, push, PR or release was performed.

## Folder search performance and deployment cleanup follow-up

The requested `deploy/telemetry` removal deletes its nine tracked deployment/operations files. App usage-statistics code and the external running service are outside this deletion; no server operation was run.

Before the ripgrep follow-up below, folder search used the in-process SearchEngine with ICU for regex and Unicode folding. It enumerated/read/hashed the folder before scanning, did not implement gitignore rules, and published completed results. Generated Swift fixtures (256 files, 8,965,120 bytes) measured ~715 ms in the initial debug run, plus a separate 180 ms UI debounce. General case-insensitive literals were being converted to UTF-16 by ICU, search decoding also computed unused line-ending metadata, and line location used checked Data subscripts for every byte.

ASCII-only case-insensitive literal patterns/text now fold through the optimized standard-library String path and reuse byte-range matching; non-ASCII inputs preserve ICU behavior (including ß, ſ and K folding). Search decoding validates UTF-8/removes BOM directly, keeps the original UTF-16 decoder and invalid-byte rejection, and does not compute save-format metadata. Line location/snippet boundary scanning pins one raw buffer within each closure. The query debounce became 80 ms. At this earlier optimization stage, no runtime dependency had been added; the subsequently approved bundled helper is described below.

The ASCII no-ICU regression failed before the change (`/tmp/duckpad-folder-fastpath-before.log`). Initial byte-by-byte Swift folding regressed debug performance and was replaced before completion. The final focused run (`/tmp/duckpad-folder-profile-fast.log`) passed real matcher option/paint, Unicode equivalence, BOM offsets, invalid input, cancellation/stale-buffer and replacement-summary checks. Generated-fixture full search measured ~158 ms; no-match case-insensitive scan measured ~13 ms instead of ~350 ms. These are local debug measurements, not a 50 ms gate or a release-build guarantee. Installed ripgrep 15.1.0 with PCRE2 searched the same fixture in ~29 ms including process start; it is an optimized external binary, so that comparison is directional, not a like-for-like build comparison.

The independent reviewer found no remaining Blocker/Major issues in the performance and deletion follow-up. At that stage, the performance changes had not yet been packaged and the launched `search-files-final` bundle predated them. The final bundled-helper build and validation below supersede that limitation. The telemetry directory is not part of either app bundle.

The final related search/replacement run (`/tmp/duckpad-folder-search-regressions.log`) emitted terminal PASS in every participating target: 134 functions passed. The generated-fixture timing function was skipped in that default run and passed separately with `DUCKPAD_PROFILE_FOLDER_SEARCH=1`; it is not counted as a default-run pass. Diff whitespace validation also passed.


## Bundled ripgrep discovery and streaming follow-up

After the user's explicit approval, packaged folder searches use a pinned ripgrep
15.1.0 helper for ignore-aware, NUL-delimited file discovery. Each incoming file
is checked through the pinned selected root with `openat`/`O_NOFOLLOW`, bounded
reads, stable file metadata and a content identity, then immediately matched by
the optimized native SearchEngine/ICU. Only the file currently being examined
needs its source bytes retained. Final Unicode folding, Extended syntax, ICU
regex/captures, UTF-8 byte ranges and replacement semantics remain unchanged.
Unsaved open documents continue to use their native editor captures.

This deliberately uses rg for discovery rather than every content match. A
prototype that copied frozen bytes into private files and launched rg once per
batch measured 27.6 ms to the first match but 222.5 ms total (178.1 ms absent)
in the signed sandbox app. The extra writes/processes regressed total time, so
that content-filter path and its unused types were removed before completion.

Selected-folder `.gitignore` and `.ignore` files are respected, including when
there is no Git repository. Global/parent ignore files, personal rg config and
PATH-installed rg are not used. Hidden files, packages and symlinks remain
excluded. File masks apply before reads and file/byte budgets. A packaged app
with a missing/broken helper fails visibly rather than silently changing ignore
scope; unbundled development runs retain the existing native fallback.

A search owns one child process and a 30-second deadline. Output/record sizes are
bounded, cancel signals target only registered children, and all exits reap the
child. Results stream off the main actor; the first match is published immediately
and later updates at most every 50 ms. A shared delivery component retains only
the latest pending UI snapshot. UI rows are capped at 5,000 while full results
remain available to Replace All. Progress snapshots are incomplete, and Replace
stays disabled until the completed nontruncated result arrives. Query generations,
close/cancel and completion guards reject late updates and retain row selection.
The existing 80 ms typing debounce is separate from engine execution time.

The helper is signed with the same identity/hardened runtime as Duckpad and
inherits its App Sandbox. Both official Apple Silicon/Intel binaries, pinned
archive checksums, architecture parity, helper signature/entitlements/team and
all 51 package notices are verified. The universal helper exists and has both
slices; this task builds only the native Apple Silicon app. The PCRE2 license
identifier includes its exception. See `Vendor/Ripgrep/PROVENANCE.md`.

Final focused validation (`/tmp/duckpad-rg-final-tests.log`) has terminal PASS for
28 test functions: six rg integration, three streaming presentation, two native
folder-replacement and seventeen matcher/use-case tests. Coverage includes
ignore/masks, UTF-16/BOM offsets, Unicode full folding, regex lookbehind/captures,
zero-length matches, NUL/newline patterns, deterministic cancellation, deadlines,
malformed/oversized child output, immutable reads, symlink exclusion, file/byte/
match limits, stale/dirty-file rejection and per-document unsaved Undo/Redo.
Eight locale catalogs pass 1,178 strings and four plurals. Manual interaction in
all eight languages and Intel hardware execution remain unverified. No commit,
push, PR, merge or release is included.


Final Apple Silicon Release bundle: `build/search-ripgrep-final/Duckpad.app`.
`/tmp/duckpad-rg-final-bundle-verify.log` and
`/tmp/duckpad-rg-final-app-smoke.log` record terminal PASS for bundle resources,
helper signatures/entitlements and Finder/Open With, bookmark/relaunch save,
window resizing, XPC isolation and packaged rg execution. Native save-panel
UI automation is explicitly skipped. Signing is ad hoc; this is not a notarized
or published release.

The actual signed sandbox app generated 256 Swift files totaling 8,965,120 bytes.
`/tmp/duckpad-rg-final-packaged-smoke.log` records 10.91 ms to the first backend
progress callback, 44.42 ms total for a matching literal and 32.54 ms for an absent
literal. The same Release app's optimized native fallback measured 31.28 ms and
25.55 ms on the same 256-file/byte set, using an explicit filename mask to exclude
the fixture's ignored directory. Thus rg discovery adds approximately 7–13 ms on
this small warm fixture, while providing ignore handling and early results;
it is not a claim that rg accelerates the already optimized native matcher.
The first-callback time excludes main-actor delivery, actual screen paint and
the separate 80 ms typing debounce. These local single-run measurements are not
a 50 ms guarantee for arbitrary directories, file sizes or regular expressions.

Independent final review found no remaining Blocker/Major issues in the
simplified implementation, tests, helper provenance or package checks. Intel
binary architecture was checked; Intel hardware and a full universal Duckpad
build were not run. No commit, push, PR, merge or release was performed.


## Four scopes and shared classic Find design

The final scope selector is All / Open Documents / Workspace / Folder. All searches
current-window editor documents plus every registered workspace root. Open
Documents includes workspace files, external files and untitled unsaved tabs, but
only those actually open in the current window. Workspace includes all registered
roots and their unopened files. Folder searches only the selected directory and
its descendants. All never implicitly includes a previously chosen external
Folder. Without registered roots, Workspace is disabled and All still searches
open documents. The selected folder path and workspace-root tooltips remain
specific to their scope.

`ProjectSearchUseCase` captures open buffers first and excludes their canonical
paths from disk reads even when the edited buffer has zero matches. Thus unsaved
contents take precedence over an older matching disk version. Repeated buffers
and canonical paths are deduplicated. More specific registered roots own their
subtrees; parent traversal excludes them so each explicit root keeps its own
ignore rules without duplicated results. Missing captures and unavailable roots
make the result incomplete. Changes to tab topology, buffer revisions or bindings
across asynchronous capture/scanning cancel the result rather than substituting
stale disk content.

File count, aggregate source bytes, matches and estimated result memory share one
budget across open buffers and roots. Capture deltas are bounded before replay;
result admission reserves document metadata and per-match/capture storage before
retaining it. Prior incomplete state is never overwritten by later complete
matches. A shared estimator accounts for the combined empty/root overhead as
well as every accepted document. Partial and truncated results cannot replace.

`ProjectDocumentsReplaceUseCase` retains separate native-buffer and disk identity
previews. Existing buffers use their original revisions and ranges; unopened files
use the same guarded inactive preparation and per-document Undo. If the disk
planning phase fails or is cancelled after open documents were changed, their
completed counts and Undo remain and the remaining files receive a cancelled or
unavailable status. Source files are never saved automatically.

Open in Find Window retains a `ProjectSearchContext` containing the actual scope,
roots and selected directory. Classic Find/Replace visibly selects that scope and
reruns only that scope for subsequent Find All / Replace All. Choosing another
scope explicitly removes the project menu item; it cannot be reselected without
its context. The explicit Find-scope popup replaces the duplicate selection
toggle, and its action labels reflect the selected scope. Changing to classic
Find in Files or Bookmarks explicitly leaves the transferred project scope.

Classic Find preserves its four tabs, actions, bookmark controls, per-document/
selection/open-document scopes and optional opacity controls. The subsequent
user correction restores its labeled native fields, checkbox/radio controls,
vertical option layout and compact 24-point actions. Only the shared panel/
section palette and compact `SearchActionButton` appearance are retained.
Find → Tab edits replacement directly and Shift-Tab returns. Localized caption
and action-column widths expand to their labels; the dialog inherits the invoking
window's appearance. The regex newline checkbox remains visible but disabled
outside regex mode, as in the original classic form.

Validation is intentionally sequential for AppKit suites, because simultaneously
creating/capturing windows caused an unrelated popup to dismiss another suite's
query. The final six sequential runs (`/tmp/duckpad-scopes-final-{native,
scope-design,classic,options,experience,streaming}.log`) emitted terminal PASS for
71 distinct test functions. These include four-scope/dirty-buffer/nested-root
integration, file/byte/match/metadata budgets, nil captures, topology changes,
cancellation after an applied edit, Undo, original-scope classic-window handoff,
menu-context reset, all eight language layouts and existing search options.
The final scope-specific tooltip adjustment has a separate focused rerun.

Sixteen new unified-Find captures cover eight locales in light and dark; English
dark and Korean light were visually inspected. All eight catalogs have 1,180
strings and four plural entries. Full manual typing/IME and visual inspection of
every locale, Intel hardware, a universal build and notarization remain outside
this local validation. No commit, push, PR, merge or release is included.


The final native bundle is `build/search-scopes/Duckpad.app`.
`/tmp/duckpad-scopes-bundle-verify.log` records PASS for resources, sandbox/helper
isolation and signatures; `/tmp/duckpad-scopes-app-smoke.log` records PASS for
Finder/Open With, bookmark/relaunch save, window resizing, sandboxed XPC isolation
and bundled rg discovery. Native save-panel automation is explicitly SKIP. This
is an ad-hoc signed Apple Silicon local build, with no universal release or
notarization. Independent final source review found no remaining Blocker/Major
issues. The previous task app was quit normally to preserve session recovery,
and this exact new bundle was launched for review.


### Classic layout correction and Korean marked-text refresh

The user rejected the classic Find layout redesign. Its original labeled fields,
native checkbox/radio controls and arrangement are restored; the requested
changes are limited to shared colors and compact button chrome. Four project
scopes and retained classic-window context remain intact.

Native field-editor regression tests reproduced missing search updates for
`사용중` and `유후 → 유ㅎ → 유휴` before the fix. AppKit updates the text view and
field value during `setMarkedText`, but `NSTextField` suppresses the control's
change delegate notification until composition commits. `SearchFieldEditor`
forwards changed marked text to the existing search delegate without rewriting
the field, forcing composition to commit or changing matching semantics. Each
input retains its own editor. The classic search field retains native
`NSSearchFieldCell` chrome through `SearchFindCell`; other search inputs use the
shared text-field cell.

`/tmp/duckpad-find-restore-ime-before.log` records the original failing layout and
IME regressions. A separate empty-composition cancellation regression failed in
`/tmp/duckpad-ime-cancel-before.log` and passes after forwarding that transition
as well. `/tmp/duckpad-ime-final.log` records five passing test functions covering
actual native matcher results, classic Find, filename and command filtering,
composition/selection preservation, cancellation, commit Undo/Redo and separate
Find/Replace editors. These tests drive the native marked-text API; manual
physical Korean-keyboard interaction is a separate validation limit.


The follow-up validation has 53 distinct functions with terminal PASS across
`/tmp/duckpad-ime-final.log` and `/tmp/duckpad-find-refined-*.log`. AppKit suites
were run sequentially. Two integration tests ended their grouped process without
a terminal result; those tests and the remaining cancellation test were rerun
individually and each recorded terminal PASS in the `isolated-` logs. Coverage
includes classic replacement routing/Undo, scope handoff, controls in all eight
languages, incremental results, popup dismissal, paste/Undo routing and existing
project options. Sixteen captures in `/tmp/duckpad-find-refined-snapshots` cover
eight languages in light/dark; English dark and Korean light were inspected.
Localizations and `git diff --check` pass. Independent review found no remaining
Blocker/Major issues in the final Find/IME changes.


The corrected local bundle is `build/search-find-refined/Duckpad.app` (native
Apple Silicon, ad-hoc signed). `/tmp/duckpad-find-refined-package.log`,
`/tmp/duckpad-find-refined-verify.log` and `/tmp/duckpad-find-refined-smoke.log`
record successful build, bundle/signature/resource checks and isolated app smokes
including bundled rg discovery. Native save-panel automation is explicitly SKIP.
The previous task bundle was quit normally; the corrected bundle was launched.
No commit, push, PR, merge or release is included in this follow-up.


### Double-Shift filename scopes

The filename popup now shares `ProjectSearchScope` and the four-way native
selector with project content search: All / Open Documents / Workspace / Folder.
Open Documents immediately uses current-window tabs, including untitled and
external files, and does not request a disk index. All merges open tabs with all
registered workspace roots. Workspace restricts seeds/indexes to registered roots,
with already-open tabs preferred on duplicate paths. Folder maintains a separate
chosen URL; it never adds that directory to registered roots or to All. Query
text survives scope changes; task/filter generations reject late indexes, stale
folder picker completions and callbacks after dismissal. Workspace is unavailable
without an available registered root. Context/browse controls and all eight
localized labels fit the popup's minimum width.

`LocalFolderFileNameIndex` uses the bundled rg name discovery/ignore configuration
and validates admitted paths with the existing pinned-root/component-no-follow
logic. No file contents are read by indexing, including binary and 128 MiB sparse
files. Development builds without the bundled helper use a bounded names-only
Foundation enumeration fallback; this fallback does not apply rg ignore files.
Count, aggregate name bytes and cancellation bound both paths. The fallback uses
realpath for relative extraction because Foundation enumerates /private/var while
normalizing the selected URL to /var.

Each Folder target retains the selected URL and indexed root canonical path/
device/inode. Activation revalidates that authority, reads every component using
O_NOFOLLOW, checks stable file bytes and validates the root again before even
looking up an existing tab. Inactive navigation receives that immutable,
fully-hashed read; project charset decoding does not trigger an unchecked path
reread. The shared request generation decides final normal/split activation.
The previous normal Open As behavior is retained. Document data is never saved
automatically, and failed reads preserve the invoking pane.

The four-way selector regression failed before the change in
`/tmp/duckpad-files-scopes-before.log`. A separate prepared binary-like UTF-16LE
snapshot with project charset failed before the reread fix in
`/tmp/duckpad-files-prepared-before.log`; it now succeeds even after the source is
removed, decoding only the validated snapshot. Root, directory and leaf link
replacement tests reject outside access. Normal/split integration waits for the
actual file-open request to finish before checking that no outside tab was opened
or activated and no split was created.

The final ten sequential runs at `/tmp/duckpad-files-final-{scope,folder-index,
design,outside-links,split,ime,experience,dismiss,conventions,prepared-workspace}.log`
record terminal PASS for 68 distinct functions with no started test missing its
completion. They cover all scopes, multiple roots/open-target deduplication,
late-index/picker cancellation, independent folder navigation, normal/split
activation, security races, immutable charset decoding, existing conventions and
workspace-read behavior, popup dismissal, Korean IME and eight-locale geometry.
Localization validation passes for 1,180 strings and four plurals in all eight
languages. English dark and Korean light captures were visually inspected;
physical keyboard IME, every locale's visual appearance, Intel hardware and
universal/notarized distribution remain unverified. No commit/push/PR/release is
part of this follow-up.


The isolated screenshot rerun (`/tmp/duckpad-files-final-snapshots.log`) completed
with terminal PASS and all 16 locale/appearance captures present. The initial
capture pass had one transient screencapture failure; the layout checks themselves
passed. Final independent review confirmed no remaining Blocker/Major findings.
The final local native bundle is `build/search-file-scopes/Duckpad.app`, ad-hoc
signed for Apple Silicon. `/tmp/duckpad-files-package.log`,
`/tmp/duckpad-files-verify.log` and `/tmp/duckpad-files-smoke.log` record successful
build, package/signature/resources checks and isolated app smokes including rg
discovery. Native save-panel automation remains explicitly SKIP. The previous
task app was quit normally and the new bundle launched for review.


### Filename tab appearance restoration

Following the user's visual correction, only the filename scope header changes
from the compact native segmented control back to the original wide text tabs.
The four `ProjectSearchScope` values remain. Existing `SearchOptionButton` chrome
provides spacing, hover/pressed feedback and the active tint; radio accessibility
roles describe their exclusive selection. Selecting an active tab keeps it active,
and unavailable Workspace remains disabled. Scope loading/cancellation, folder
authority and normal/split activation logic are unchanged.

Validation reuses filename layout/click, scope integration and Korean marked-text
suites. All eight locales fit the 520-point minimum width. Sixteen captures in
`/tmp/duckpad-file-tabs-snapshots` cover light/dark across eight locales; English
dark and Korean light were inspected. AppKit process isolation is recorded in the
`/tmp/duckpad-file-tabs-isolated-*.log` reruns rather than treating an early exit
without terminal PASS as successful completion.


This appearance follow-up has 15 distinct test functions with terminal PASS in
`/tmp/duckpad-file-tabs-*.log`, including the isolated scope cases. The Browse
cancellation test dispatches the button's actual target/action directly so native
`performClick` animation does not end its async SwiftPM helper before completion.
The local bundle is `build/search-file-tabs/Duckpad.app` (native Apple Silicon,
ad-hoc signed). Package build, verification and isolated smoke checks pass in
`/tmp/duckpad-file-tabs-{package,verify,smoke}.log`; native save-panel automation is
explicitly SKIP. The prior task app was normally quit and the corrected tab-style
bundle launched. No commit, push or release was performed.
