# Built-in declaration navigation

Hold Command while hovering over a code token to underline it and display a
pointing-hand cursor when the bounded declaration lookup finds a candidate.
Releasing Command removes the decoration without moving the caret. Comments and
string literals are excluded. After a 120 ms debounce, the current document is
analyzed off the main thread and the same lookup used by clicking checks open
buffers and registered workspace roots when needed. Unchanged-document pointer
motion reuses the token index; completed hover results are shared with clicking
for two seconds. Unsupported languages and documents over 4 MiB skip hover before
copying text. A candidate is a lexical name match, not a semantic guarantee.

Declaration jumps and navigation Back/Forward place the target near 20% of the
active pane's visible text height. Folded targets are expanded and soft-wrapped
display rows are accounted for. At the beginning/end of a document, existing
scroll bounds can prevent exact placement. Search-result scrolling is unchanged.

Press F12 or Command-click an identifier to find declaration candidates without installing a language server. Search > Go to Declaration exposes the same command. Navigate Back and Navigate Forward use Control-minus and Control-Shift-minus. History is local to the window and retains up to 100 locations in each direction; edited documents use the saved line/column as an approximate return location.

The built-in lexical index recognizes common named functions, types, variables and parameters in Swift, JavaScript/TypeScript, Python, Rust, Go, C/C++, Java and C#. A unique declaration in the current lexical scope jumps immediately. Overloads, member accesses and results from other files appear in a searchable candidate list with file, line and a bounded code preview. Enter/double-click selects a candidate; Escape dismisses the list. Existing unsaved buffers, including untitled documents with a manually selected language, take precedence over disk contents.

This is syntax-based navigation, not semantic reference resolution. It does not resolve receiver types, imports, overload signatures, macros, inheritance, destructuring, all language-specific declaration forms, or prove that two uses of a name refer to the same symbol. Ambiguous JavaScript slash syntax and C++/Swift/Rust raw string literals can leave a document unresolved. A language server is not installed or started by this feature; semantic definition/reference navigation remains a separate extension to implement.

Press Shift-F12 or choose Search > Find Reference Candidates to list uses of the
identifier in the current document, compatible open buffers and registered
workspace roots. Recognized declarations, comments and string literals are
excluded. Results show file, line and code context, and use the same navigation
history and 20% viewport placement. The list explicitly labels these as name
matches: shadowed variables, unrelated members and same-named types can appear
together. This remains useful without an LSP; precise semantic references need a
future language-server provider.

Protocol Buffers (`.proto`, language ID `protobuf`) also supports hover and
navigation to `message`, `enum`, `service`, `rpc` and `oneof` declarations.
RPC request/response names are references to message types, not local parameter
declarations. Nested types use the enclosing lexical scope. Other open `.proto`
buffers and registered workspace roots participate in name-based candidate
lookup; package/import resolution, fields and enum-value declarations are not
implemented. Syntax highlighting support alone does not imply declaration
navigation support for every language in the editor's language menu.

## Zed navigation reference

Reviewed Zed's public source on 2026-10-16:

- [navigation.rs](https://github.com/zed-industries/zed/blob/main/crates/editor/src/navigation.rs)
  separates definition/declaration/type/implementation queries from references,
  uses semantic providers for definition locations and project reference queries,
  and presents multiple locations with surrounding code in a multibuffer. Its
  definition action can fall back to references. Navigation history is separate
  from resolving locations.
- [hover_links.rs](https://github.com/zed-industries/zed/blob/main/crates/editor/src/hover_links.rs)
  collects definition/document-link targets for the hovered range and uses that
  link state for highlighting and clicking. Duckpad now shares its bounded lexical lookup and
  completed results between hover and click.
- [autoscroll.rs](https://github.com/zed-industries/zed/blob/main/crates/editor/src/scroll/autoscroll.rs)
  applies a navigation-specific scroll strategy. Zed's default is center; Duckpad
  uses the requested 20% position rather than copying that default.

The useful architectural boundary is location lookup versus presentation/history.
Duckpad's bounded lexical analyzer can provide baseline candidates without an
LSP, while a future semantic provider can refine them. References are a distinct
query that returns explicitly labelled name-based candidates. Name-only cross-file/qualified candidates can
be ambiguous even when only one candidate is found, so Duckpad currently retains
the candidate picker for those cases.

## Bounds and stale results

Analysis runs on demand, outside the typing path. Each source file is capped at 4 MiB and 200,000 tokens. Open-buffer lookup is limited to 16 MiB; project lookup uses only explicitly registered workspace roots, within the existing symlink-resistant root store. It stops at 256 directories, 512 source files, 10,000 entries, 32 MiB of content, 200 candidates or a cooperative three-second deadline. A filesystem read already in progress can exceed that deadline. Dependency/build/hidden directories are excluded. A partial search is labelled in the candidate list. JavaScript/TypeScript and C/C++ share language families; unrelated languages are excluded.

Changing the source caret, pane, buffer revision or roots invalidates pending navigation results. Hover caching validates the source bytes, pane, token range, roots and workspace generation; edits in another tab invalidate it too. Cancelled or reloaded hover requests cannot restore an old underline. Activation validates the exact destination tab, buffer, pane and caret after awaiting persistence, and compares candidate contents before selecting. Candidate navigation does not modify document content or undo history. Files over the analysis budget remain editable, with navigation unavailable for that document.

## Validation

- `DeclarationIndexTests`: Unicode byte ranges, scopes/parameters, Python suites, JavaScript regex literals, language families, reference exclusions, bounded previews and input limits.
- `WorkspaceDeclarationSearchTests` and `LocalWorkspaceRootStoreTests`: bounds, partial results, open-buffer exclusion, compatible languages and symlink/path safety.
- `DeclarationNavigationTests`: native Command-click, F12/Shift-F12 menu bindings, local/history navigation, exact-tab activation, stale caret rejection, unsaved reference candidates, shared hover results and project-cache invalidation.

Validated on 2026-10-16 (Apple Silicon, macOS 27.0.1): all 1,193 Swift tests
passed (461 presentation, 346 editor adapter, 208 application, 161 infrastructure,
14 domain and 3 app tests). The pre-existing `MenuPresentationSpy` compiler error
was fixed by capturing its callback before entering `MainActor.assumeIsolated`.

Xcode's SwiftPM helper can exit from `swift_task_asyncMainDrainQueue` before
finishing a combined AppKit run, even with exit status zero. Presentation tests
were therefore run in fresh serial helper processes by suite and individually
for top-level tests, requiring the expected count and a passing terminal summary.
The remaining five bundles completed serially. Native coverage includes delayed
lookup cancellation, same-revision reloads, language changes, shared-pane
invalidation, unsaved reference navigation/history and project-cache invalidation.
The native hover test window simulates key-window state because the helper has
no application activation event loop.

All 751 strings and four plural entries validate in all eight supported locales.
The candidate panel was rendered and visually checked in each locale, including
its file/line/code rows, search placeholder and partial-result status. Automated
layout/accessibility checks and English fallback tests pass; resource loading
covers both flat and macOS `Contents/Resources` bundles. History shortcuts use
Control-minus and Control-Shift-minus to avoid the existing folding shortcuts.

A full Release input matrix covered 14 approximately 9.18 MB fixtures (JSON, JavaScript, CSS, XML, plain/Unicode/tab-heavy text, logs and multiline sources). The final accepted fixture runs passed all 10,752 editing events with a 43.19 ms maximum; first-input cycles (input handling plus native queries, status, drawing and layer flush) reached at most 27.06 ms. Loading precedes these measurements. Initial emoji, combining-character and original-JSON stress runs exceeded 50 ms (147.11, 63.85 and 67.15 ms); clean 0.10.4 comparison runs and unchanged 0.11.0 rechecks passed. The spikes did not reproduce, and their cause is not established. All measurements, including failures, are retained in the validation evidence; these fixture-specific results are not a hard real-time guarantee for arbitrary workloads or system load.

See [validation evidence](declaration-navigation-validation.json). This measures native input responsiveness, not project-search latency or app launch. Reproduce with `scripts/run_long_line_performance.py --positions end --json-fixture <path>`.

Project search currently indexes UTF-8 source files. Other encodings can still
participate through an already-open editor buffer, where the editor supplies
decoded UTF-8 content.
