# Phase 11 — Workspace Chrome and Document Dropdown

- **Status:** Phase 11 delivered; visible document-dropdown chrome superseded by Phase 33
- **Owner/agent:** `/root` direct builder
- **Last updated:** 2026-09-03
- **Related:** [Multiline tab workspace](08-multiline-tabs.md), [Searchable document switcher](15-searchable-document-switcher.md), [Editor groups and native tabs](38-editor-groups-compare-and-native-tabs.md)

## Current chrome contract

Duckpad preserves the familiar Notepad workflow: command ordering, document
tabs, and status fields stay recognizable; improvements focus on interaction
quality and native macOS behavior.

The bottom bar follows the reference order: language, `Length` / `Lines`,
`Ln` / `Col` / `Sel`, line endings, encoding, and `INS` / `OVR`. Subtle separators
divide the fields in both appearances. Language, line endings, encoding, caret
navigation, and insert mode remain actionable. Extension and symbol commands
remain in their menus rather than occupying the document-status row. Length is
the editor's byte length; selection counts Unicode characters and selected lines.
Native content/selection notifications update the counters without copying the
document. Unchanged selection counts are cached, and scrolling does not rescan
the selection.

Actionable status fields show hover, pressed, and disabled feedback in the
window's own appearance. Line endings open LF / CRLF / CR choices at that field;
encoding opens its own choices. Both retain the existing convert-and-save actions.

**View → Theme → System / Light / Dark** switches all windows and editors using
the same saved preference as Settings. Quick theme changes preserve editor
defaults, serialize with Settings edits, and finish before application termination.

The window command bar uses native visual-effect material and menu typography.
Titles are centered in equal left/right padding; title padding and the gaps
between menu buttons are 1.3 times the previous compact spacing.
While a dropdown is tracking, moving across another title immediately switches
the native menu without requiring another click. A short-lived timer runs only
in AppKit's menu-tracking run-loop mode, because ordinary view tracking events
are not reliably dispatched there. Dismissal and teardown stop the timer.
The real native menu probe runs in an isolated test process:
`DUCKPAD_NATIVE_MENU_PROBE=1 swift test --no-parallel --filter nativeMenuTrackingLoop`.
The regular suite covers the same switching and dismissal states with menu
spies; isolation prevents AppKit's process-wide menu loop from terminating an
unrelated later test.

[Phase 33](38-editor-groups-compare-and-native-tabs.md) removes the visible
Open Documents/`Documents (N)` control and every width reservation for it. The
searchable switcher remains available through **Tabs → Open Document…** and
`Command-Shift-O`, anchored to the tab-strip surface. Phase 11's visible right-side
button description below is retained only as historical delivery evidence.

The current window keeps the native macOS main menu and adds one slim
window-local command bar above all editor groups. Each compact
`NSPopUpButton`-compatible trigger retains the exact original `NSMenu`
object—not a copied item tree—but routes mouse, keyboard, and accessibility
presentation through an explicit menu-content anchor one point below the bar.
Menu identity, supermenu attachment, targets, selectors, shortcuts, state,
hidden items, and validation therefore remain authoritative. Dark/Light Aqua
receive semantic hover and open feedback, while teardown/reapply restores the
original menu attachment and visibility state.

Tabs are connected multi-row strips with complete, never-ellipsized titles and
compact title-side whitespace. Each tab keeps its measured intrinsic width, so
a short row leaves ordinary trailing room instead of stretching to fill 100%.
Wrapping adds a row only when the next whole tab no longer fits. There is no
visible or internal tab viewport; every row remains in the window at full
content height, and wheel/selection/resize cannot move the clip origin or
expose scroller chrome.

The modified-document dot is vertically centered beside the file icon. Pin
controls reserve a 20 × 20 click target without moving the title on hover.
Hovering a pinned tab's pin shows the unpin symbol and a local rounded highlight;
pressing strengthens that feedback. Pin clicks do not activate or close the tab,
and mouse/accessibility actions respect the workspace interaction lock.

## Window geometry

The root content view starts at the window's 900 × 620 content size; installing
an empty, zero-sized content controller must not shrink the window to its
minimum height. Centering happens only when no saved frame exists, so reopening
or refocusing an existing window keeps its position.

Move and completed resize events persist each recovery window's frame to the
explicit `com.namjeongwan.duckpad.window-frames` defaults suite. This does not
rely on the executable bundle identity when launched with `swift run DuckpadApp`.
New windows can use the last frame from the same recovery namespace; restored
windows retain their own frames. Invalid stored geometry uses the initial size,
and frames from disconnected displays are constrained to an available screen.

## Historical Phase 11 goal

The first functional UI exposed the editor engine, but it did not yet present a
cohesive macOS workspace. A hidden persistence banner still reserved 36 points,
the tab row started at 42 points, status labels floated over the editor, the
line-number gutter ignored the dark palette, and open documents or language
selection were discoverable only through menus.

This phase makes those existing capabilities visible without adding a document
organizer or changing scratch-first behavior.

## Historical Phase 11 interface

- The empty persistence banner now collapses to zero height and expands only
  when an actionable persistence failure is presented.
- The multiline tab row is 34 points high with 28-point tabs, tighter spacing,
  restrained semantic colors, a two-point active indicator, SF Symbol pin/close
  controls, and close affordances shown only for the active or hovered tab.
- Historically, the right side of the tab strip contained native New Scratch
  and Open Documents buttons. Phase 11 originally used a flat native menu with active, edited,
  pinned/file/scratch and path state. [Phase 12](15-searchable-document-switcher.md)
  supersedes that menu with the current searchable keyboard-first popover while
  preserving stable-`TabID` routing.
- A real 24-point status bar owns extension and language controls outside the
  editor frame. Extension status opens the manager. Language status opens the
  bounded native alphabet menu shared with the command bar; Automatic
  Detection, Plain Text, and the current automatic/manual check state remain
  direct and authoritative.
- Scintilla now styles the line-number and fold margins for light/dark palettes,
  uses a smaller coherent gutter, adds editor text padding and line spacing, and
  gives the caret line a low-alpha highlight. The `NSTextView` fallback uses
  native semantic text, background, caret, and selection colors.
- The bundled application icon now uses the replacement Duckpad duck-and-pencil
  artwork supplied on 2026-09-03. Its outside canvas is transparent, and the
  artwork is centered at 84% scale to match the visual footprint of neighboring
  macOS Dock icons. The standard ten PNG representations are packaged into the
  runtime `.icns`.

Untitled arbitrary text remains Plain Text by design. Saving a recognized file,
pasting content with a supported detector signature, or choosing a language in
the new status dropdown activates the existing Lexilla syntax styling.

## Architecture and performance

In the Phase 11 implementation, `DocumentSwitcherButton` was a Presentation adapter over immutable
`TabSnapshot` values. It forwards only `TabID`; workspace mutation remains in
`ScratchWorkspaceUseCase`. Structural tab changes rebuild its native menu, while
ordinary buffer edits update exactly one menu item. This preserves the existing
500-tab hot-path contract and avoids rebuilding hundreds of document rows on
every keystroke. Active-tab changes configure only the previous/current pair,
and explicit inspection metrics verify the same constant work at 500 and 5,000
open tabs.

Termination admission is acquired synchronously by the shared native
coordinator before its async review task begins. It disables tab, document,
language, and extension chrome, guards queued actions, and remains closed across
later ready-state publications. Only a denied termination restores interaction;
an approved termination stays locked through application exit.

Palette work remains in the Scintilla Objective-C++ boundary. No AppKit or
Scintilla types moved into Domain or Application, and UI changes do not mutate
text revision, undo history, dirty state, file binding, or recovery data.

## Validation

- Focused document-dropdown, 500/5,000-tab constant-work, termination-admission,
  compact-chrome, Scintilla palette, and exact icon representation/alpha/ICNS
  round-trip tests pass. The 16/32-point 1x legacy `ic04`/`ic05` chunks have a
  bounded `iconutil` edge quantization; all modern PNG chunks are pixel exact.
- Debug and Release full suites pass with 200 tests each. An earlier parallel
  Debug run exposed one pre-existing persistence timing flake; its isolated test
  and clean full rerun passed.
- A clean macOS 13 x86_64 release build/link and the production Scintilla
  50-tab multiline smoke pass. The exact independent review and candidate
  freeze were subsequently completed, as recorded below.
- README files, the ignored Notepad++ checkout, and the pre-existing unstaged
  implementation-foundation/vendor-script files are outside this change.

## Independent review remediation

- P11-01: removed the full document-menu state scan and the tab-strip selection
  scan from the ordinary edit path. One edit configures one authoritative item;
  active change configures at most two.
- P11-02: moved termination UI admission ahead of task scheduling, preserved the
  lock through ready events, guarded direct/queued chrome actions, and restored
  controls only after a denied review.
- P11-03: expanded icon coverage to all four corners, centered 84% alpha bounds,
  and every `iconutil`-extracted representation with exact or platform-bounded
  RGBA comparison according to ICNS chunk encoding.

## Commit evidence

- Candidate ID: `9e371fd9103b5106e785db6ec23800b8f073b7b5dc3f1e3869ce576ba5370938`
- Independent review: approved — 0 Blocker, 0 Major, 0 Minor
- Local receipt SHA-256: `60bcabb07d116c86e1a5095ecc8aace53b1fb31abc46ed43d11487bc4abd4637`
- Commit: `fff6c1cc1b3b27ab28f98f45c8ade92b16d46d08`
- Delivery: `origin/main`
