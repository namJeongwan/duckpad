# Phase 22 — Current-document completion and symbol outline

Status: **Implemented; remediation re-review pending**

## User contract

Duckpad now provides useful navigation assistance without turning scratch text into a project. `Control-Space` opens Scintilla's native completion list from words already present in the active document plus the active language's bundled keyword lists. `Command-Option-O` opens a searchable native symbol outline for the active document; Return or double-click reveals the exact UTF-8 name range in the editor.

Completion is case/diacritic-insensitive for matching, preserves the source spelling shown to the user, removes duplicates, omits the already-complete prefix, sorts deterministically, and caps the list at 200 items. The outline caps at 500 symbols and recognizes common type, function, property, Markdown heading, INI section, and JSON-property forms. It is intentionally a bounded local fallback, not a claim of compiler-semantic accuracy.

## Architecture and safety

`DocumentIntelligenceUseCase` and `DocumentIntelligenceAnalyzer` live in Application. The editor-facing port exposes one bounded immutable UTF-8 capture and narrow completion/reveal commands; no Scintilla type crosses inward. `ScintillaEditorAdapter` validates the active buffer, revision, focused split pane, caret and IME state immediately before presenting candidates. The Objective-C++ bridge exposes completion intent rather than raw Scintilla messages.

Documents above 4 MiB are rejected before a snapshot allocation. Completion streams bounded 256-byte words, retains only the deterministic best 200 candidates, and reads at most 256 KiB of supplemental terms. Symbol discovery streams CR, LF, and CRLF boundaries, byte-prefilters ordinary ASCII non-symbol lines before allocating a String, checks cancellation every 1,024 lines, skips individual lines above 16 KiB, and stops after 500 symbols; it does not first materialize every line. Scanning runs in a detached value-only task.

A capture carries an opaque identity for the exact focused editor pane in addition to buffer, revision, and caret. Publication therefore fails if focus moved to the other split pane even when both panes share the same document and caret. A tab switch, close, restore, reload, termination admission, or window teardown cancels pending work and native completion UI. An edit made while analysis is running changes the authoritative revision, so stale results cannot publish. Once a native completion list is visible, ordinary typing remains owned by Scintilla so it can filter the list and preserve its existing undo/revision notification path.

The symbol popover supports incremental folded search, keyboard Up/Down/Return/Escape, semantic icon/label/kind/line metadata, Reduced Motion, host-window close teardown, and exact-buffer/revision checking before navigation.

## Validation

- Pure Application tests cover Unicode completion prefixes, language keyword input, duplicate filtering, exact UTF-8 symbol ranges after Korean/emoji content, language-scoped Markdown headings, mixed LF/CRLF/CR offsets, adversarial 4 MiB unique words and two-million short non-symbol lines with a Debug work ceiling, over-budget rejection, stale publication, and stale symbol navigation.
- Scintilla tests cover non-mutating native list presentation/cancellation, verify the document-size budget is checked before any full snapshot read, and reject same-buffer/same-revision/same-caret publication after split-pane focus changes.
- AppKit tests cover exact shortcuts/selectors, disabled commands without a capable editor, controller routing, termination cancellation, searchable symbol filtering, diacritic matching, and stable symbol activation.
- A production executable smoke types a real buffer and verifies two exact completion candidates plus the parsed function symbol.
- The initial independent review found two Majors and one Minor; bounded streaming, exact-pane authority, and CR-only scanning remediations plus focused regressions are now implemented. Exact-current Debug and Release each pass 313/313 tests, the Release production smoke passes, parity passes 31/31, commit governance passes 8/8, and the default checker exits successfully. Independent re-review, signed receipt, commit, and push are pending.

## Deliberate boundary

Language-server/API semantic completion and call tips require a separately bounded provider contract and remain a later extension of this port. This slice does not read a project, execute source, use network access, or change document bytes merely to analyze them. Macro recording/playback remains excluded. README, the ignored Notepad++ checkout, and user-owned doc04/vendor-script changes are untouched.
