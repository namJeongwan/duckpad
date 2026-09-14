# Built-in formatting

Use **Edit → Format Document**, or **Shift–Option–F** (`⇧⌥F`) on macOS.
The shortcut follows VS Code's macOS Format Document binding:
https://code.visualstudio.com/docs/editing/codebasics.

In **Preferences → Formatting**, enable **Format on Save** to format before
Save, Save As, Save All, and a save requested while closing a document. It is
off by default, including when loading settings saved by older Duckpad
versions. Save Copy As retains its point-in-time copy behavior.

Preferences control print width, indentation width/tabs, single quotes,
semicolons, and the SQL dialect. These are application preferences, separate
from the editor's typing indentation settings. Unsupported languages save
normally. An automatic formatting error leaves the text intact and saves without
a formatting alert. This includes syntax errors, timeouts, size limits, and
formatter availability errors. An edit or tab switch during formatting still
invalidates the result and cancels that save attempt. Actual file-save failures
retain their normal error handling.

Explicit **Format Document** commands report failures. Syntax diagnostics show
only the first diagnostic line (up to 300 characters), including the source
location when supplied by the engine; the source code frame is omitted.

## Included engines

- Prettier 3.9.6: JavaScript/JSX, TypeScript/TSX, JSON/JSONC/JSON5, YAML,
  HTML/Vue, CSS/SCSS/Less, Markdown/MDX, GraphQL, and Handlebars (`.hbs`).
- Prettier XML plugin 3.4.2: XML, XSD, XSL/XSLT, SVG. Strict whitespace mode
  preserves text content and spacing between tags; it may keep compact XML
  on one line. Attribute layout can still be formatted.
- SQL Formatter 15.8.2: selectable SQL, PostgreSQL, MySQL, MariaDB, Oracle,
  SQLite, and SQL Server. Dialect support does not imply support for every
  database feature; stored procedures and custom statement delimiters are
  unsupported by the bundled SQL engine.

An explicit language selection wins over the filename. Otherwise the filename
selects the parser, including the destination filename on the first Save As.
The active detected language is the fallback for scratch documents.
Python and Rust formatters are not included in this change.

## Editing and runtime behavior

Formatting uses a bounded diff applied as one native undo action. The editor
retains its existing undo history and adjusts selections/bookmarks with edits.
The diff works directly on contiguous UTF-8 and consumes changed whitespace
runs before looking for token matches. This keeps short unchanged tokens outside
replacement ranges and avoids repeated lookahead across newly inserted gaps.
Reapplying identical formatting adds no undo step. Existing LF, CRLF, or CR
line endings are retained; mixed line endings normalize to LF. The normal save
pipeline preserves the selected encoding and BOM.

An unchanged revision with the same parser, settings, and bound line ending skips
the snapshot and formatter after a successful format. Only one revision key is
retained, without document contents. Edits, Undo/Redo, another buffer, or changed
formatting options require formatting again.

Formatting runs offline in WebKit's content process. Node.js is only a build
tool for regenerating the checked-in bundle. Prettier standalone does not load
`.prettierrc`, `.prettierignore`, project configuration scripts, or external
Prettier plugins. App preferences are the formatting configuration for this
version. Inputs are limited to 1 MiB and output to 4 MiB, with a 15-second
request timeout. A running IME composition is not replaced by formatting.
One WebKit runtime is reused for nearby requests and released after 30 seconds
idle. Cancellation, timeout, and runtime failure invalidate it; syntax errors can
reuse it. The deadline stops waiting for a result, but cannot forcibly interrupt
synchronous JavaScript. An invalidated evaluation must finish before another
runtime can start; formatting reports busy in the meantime, preventing overlapping
replacement workers from accumulating memory. Request identifiers isolate late completions/cancellation from the
next request. Releasing a runtime does not guarantee immediate process RSS
reduction; WebKit and the system allocator manage that memory.
JSON/JSONC/JSON5 initially load a 612,280-byte bundle containing the same upstream
Prettier parser/printer, instead of the 4,090,836-byte full language bundle.
Requesting another language upgrades the single runtime to the full bundle;
subsequent JSON requests reuse it. The two bundles are checked for equal output.

See [bundle provenance](../Sources/DuckpadInfrastructure/Resources/Formatter/PROVENANCE.md)
for exact versions, integrity metadata, licenses, and regeneration commands.

## Verification (2026-09-14)

See [cross-language performance probes](formatting-performance.md) for measured
JSON/YAML/SQL results at 32 KiB and 256 KiB and reproducible fixture generation.

- 23 formatting tests pass: actual bundled parsers, idempotence, SQL dialects,
  options, invalid input, limits, timeout/cancellation, Unicode diffing,
  large minified JSON and bounded syntax diagnostics without source code frames,
  settings migration, native selections/Undo/recovery, stale pane/revision
  rejection, Save As/Save All/close-save, encoding/EOL preservation, and
  English/Korean settings controls. Automatic syntax/timeout/size/availability
  failures save unchanged bytes without opening a sheet. Batch formatting keeps
  Unicode selections, recovery data, Undo/Redo, and fold headers while explicitly
  styling at most the final document size once.
- Runtime reuse, idle release, overlapping calls, cancellation followed by
  another request, draining timed-out/cancelled JavaScript before runtime replacement,
  syntax-error recovery, and revision/settings cache invalidation
  are covered. Recovery delta appends now mutate the dictionary value in place,
  avoiding an array copy for every edit while preserving immutable captures.
- A whitespace-only formatting regression originally replaced unchanged short
  JSON tokens (six failed assertions). It now verifies only whitespace is
  replaced. UTF-8 tests include canonical-equivalent but byte-distinct strings,
  shared multibyte prefixes, long whitespace runs with differing trailing tokens,
  and the 10,000-edit limit with a valid-UTF-8 remainder replacement.
- A 268,592-byte minified workflow JSON probe with JSON highlighting enabled
  reduced result application from 53.75 seconds to 3.44 seconds in a debug
  build; formatter execution was about 0.3 seconds in both runs. The remaining
  application time was mostly the background diff (about 3 seconds). The probe
  read the user fixture without modifying it; the repository regression uses
  synthetic JSON and checks styling work rather than wall-clock timing.
- Native Undo/Redo now advances revisions and recovery deltas for every edit,
  but publishes workspace/UI changes and schedules persistence only once per
  action. The 268,592-byte user-fixture probe reduced process peak-memory growth
  during Undo from 152 → 633 MB to 155 → 159 MB, and Undo time from 8.66 to
  2.24 seconds (debug test process, decimal MB; not a GUI release measurement).
  A synthetic large JSON regression saves formatted output and performs three
  Undo/Redo cycles, checking exact text, recovery, revisions, and one publication
  per action. The user document was read only.
- A follow-up live-memory probe used the normal 250 ms recovery autosave and
  checkpoint acknowledgement, with temporary fixtures only. Resident memory
  was 162.6 MB before Undo, 163.7 MB immediately after, 164.0 MB after 1 and
  5 seconds, and 158.5 / 160.4 / 163.3 MB after three further Redo/Undo cycles.
  Physical footprint was 61.0 MB before Undo and 60.7 MB after the final cycle.
  These debug-process measurements distinguish live memory from the earlier
  peak statistic: they do not promise immediate RSS return or establish
  long-duration leak freedom. Native Undo/Redo history remains available.
- A Release benchmark on the same 268,592-byte JSON reduced first formatting
  from 639 ms to 374 ms, repeated formatting after Undo from 524–546 ms to
  128–149 ms, and Undo from 1,912–1,982 ms to 117–134 ms. Formatting an unchanged
  revision took 0.04 ms instead of 182 ms. The benchmark includes engine execution,
  diffing, and native edit application with JSON highlighting; it uses a temporary
  copy and verifies Undo restores the original bytes. It does not measure visible
  GUI frame presentation or compare identical formatter engines in Zed/VS Code.
- Further profiling found roughly 5.2 million lookahead iterations on that
  fixture. Consuming whitespace gaps directly reduced edits from 9,681 to 3,324
  and diffing from about 27 ms to below 1 ms. Combined with the compact JSON
  runtime, Release probes measured first formatting at 215–255 ms,
  repeated formatting at 86–97 ms, and Undo at 52–56 ms. The final packaged-source
  probe measured 255 ms cold, 93–97 ms repeated, and 52–55 ms Undo. These are local benchmark
  observations, not latency guarantees or a head-to-head Zed comparison.
- 71 focused tests pass, including related native Undo/Redo, Korean composition,
  shared panes, recovery, comment commands, search replacement, and formatting.
- Native release app builds and passes deep/strict code-signature verification.
  The 2026-09-11 packaged smoke verified bundled resources, actual formatter
  execution, menu action registration, native Undo, and settings persistence.
  A later 2026-09-14 rerun with separate stages passed menu binding/validation
  and failed specifically at `synthetic keyboard event dispatch`. This does not
  establish physical key delivery. `DUCKPAD_FORMATTING_SMOKE_MENU_ONLY=1` selects
  an explicit menu-action smoke without weakening the default keyboard check.
  The universal 0.4.0 packaged app passes this menu-only smoke, including actual
  formatter execution, native Undo, and settings persistence.
- Actual keyboard delivery and visual screenshots remain unverified. The packaged native Save
  panel grant is also unverified; sandbox file access rules were left intact.
- Broader settings/file-routing validation found one existing failure:
  `routedFolderSearchOpensIdentityCheckedResultAndSelectsUTF8Range` still looks
  for the detached search controls inside the document window. The same failure
  was reproduced on unchanged `origin/main` (`b65f422`) in an isolated checkout.

Run the focused checks from the repository root:

```sh
swift test --filter 'BuiltInFormattingTests|FormattingEditsTests|DocumentFormattingIntegrationTests'
DUCKPAD_FORMATTING_SMOKE=1 .build/debug/DuckpadApp
swift run -c release DuckpadPerformanceBenchmark --format-json /path/to/fixture.json
```
