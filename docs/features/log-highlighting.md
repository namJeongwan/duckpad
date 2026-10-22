# Log highlighting (phase 3)

Local files, SSH snapshots and Tail output use the same native Log language.
The implementation recognizes common log structure rather than depending on a
Python, Rust, Java or other logging-library SDK. There are no new dependencies.

## Choosing Log

`.log`, rotated names such as `app.log.1` and `app.log.2026-10-22`, and the names
`syslog`, `messages`, `access_log` and `error_log` select Log. Otherwise automatic
detection inspects at most the first 16 KiB, 64 physical lines and 512 bytes per
line for SGR, severity fields, timestamps or common level/logger prefixes.
Existing specific language associations take precedence. Compressed files are
not decompressed by this feature.

Use the language menu to select **Log** explicitly, or **Plain Text** to see the
raw control sequences. A manual choice wins over automatic detection. Tail
reuses its initial positive detection result; normal editable documents are
rechecked after their content revision changes.

## Appearance and original data

Common timestamp, TRACE/DEBUG/INFO/WARN/ERROR/FATAL aliases, structured
`level`/`severity`/`levelname` keys and stack-trace headers have distinct roles.
Header recognition is bounded to 512 bytes per physical line; this is not a
complete parser for every possible logging format. Four editor palettes are
supported, with stronger emphasis on errors and fatal messages.

Complete semicolon-separated ANSI SGR supports the basic 16 colours, the 256
colour palette, RGB foreground/background, bold, italic, underline, dim, inverse
and resets. SGR controls are hidden visually using a native invisible style.
The original UTF-8 bytes, positions, selection, search, copy and Undo history
are retained. Styling never edits or saves the file. Switching to Plain Text
restores control visibility and clears ANSI decorations.

Only complete SGR of at most 128 bytes and 32 parameters is interpreted.
Partial controls are revisited when more Tail bytes arrive. OSC hyperlinks,
cursor motion and unsupported escape families remain raw text; the editor does
not execute terminal commands. ANSI RGB is retained as supplied and therefore
can have poor contrast if the producer chooses unsuitable colours. Find and
word-occurrence overlays paint above ANSI backgrounds.

## Bounded work

The Duckpad-owned `duckpadlog` lexer scans in 16 KiB main-queue slices, with up
to 128 bytes of SGR lookahead and a soft 2 ms parsing budget. Completed native
style changes and system scheduling can exceed that soft budget. Full ANSI
state checkpoints are recorded roughly every 16 KiB, capped at 16,384 entries.
Older evicted checkpoints can require a larger rescan after an edit far back in
a very large file. Initial colouring progresses asynchronously.

Unformatted text retains native default style 0. Log uses the native visible
page layout cache so colour-only updates do not repeatedly reshape a long
Unicode line. Other languages retain their existing cache configuration.
Bold/italic/underline and hiding an escape change glyph layout; very large
single lines with many such changes are not covered by a universal 50 ms
rendering guarantee. Initial file loading and network latency are separate
from the incremental colour-work measurements. The 18,900,005-byte single-line
Unicode fixture with only one cyan SGR already exceeds the 50 ms frame goal
(53.8 and 66.1 ms in serial runs). This remains an open first-colour-layout
performance limitation, even without dense font-attribute changes; parsing
slices and subsequent Tail appends meet their separate measured budgets.

## Validation

The shared-pane/wrapped/minimap Tail measurement times each append plus its
immediate layout/display. Awaiting subsequent asynchronous colouring is outside
that measurement; it does not establish that every later frame is under 50 ms.

See [log-highlighting-validation.json](log-highlighting-validation.json) for
final results. Native tests cover all four palettes, unchanged bytes and Undo,
manual Plain Text, partial escapes, RGB/256/background colours, document
rotation, lexer replacement during pending work, dense checkpoint-boundary
edits compared with a fresh lexer, and actual pixel changes for Find and word
occurrences. Application tests cover automatic/manual language selection and
Tail detection reuse.

During development, replacing a lexer with queued work exposed an escaping
block that captured a `shared_ptr` reference rather than its value. The fixed
block retains state and rejects work after lexer destruction. An isolated
AddressSanitizer harness reproduces heap-use-after-free with the reference
capture and passes 64 lexer/document destruction repetitions with the fix.

References consulted: [Log File Highlighter](https://github.com/emilast/vscode-logfile-highlighter)
for generic log categories and the [Scintilla API](https://scintilla.org/ScintillaDoc.html)
for invisible styles and value-colour indicators. No extension grammar was
copied or added as a runtime dependency.

The phase-3 colour-only native preview is `build/tail-phase3-preview/Duckpad.app`,
version 0.14.3 (65), ad-hoc signed and not notarized. Bundle verification and
serial general smokes pass (Finder/Open With, resize, sandboxed extension and
isolation, ripgrep). The packaged language smoke also passes actual RGB
indicators and Plain Text cleanup. Native save-panel automation is skipped.
Twenty-one focused functional test functions and 84 existing language/editor
regressions pass in the final non-stress/isolated runs. The 8.44 MB multiline
ANSI fixture with shared panes, wrap and minimaps records a 1.44 ms maximum
immediate append/display over six 42,200-byte appends. Its asynchronous colour
completion is outside that measurement. The 19 MB single-line frame gate
remains failed as described above. A recovery metadata assertion that failed
under concurrent stress load passes in the isolated full 84-function suite.

Intel hardware, production SSH servers, physical IME interaction and full
colour-completion frame timing for the shared wrapped fixture are unverified.
No version bump, Git integration or release is performed for this preview.

The subsequent [Find input latency fix](find-input-latency.md) is included with
these colours in the latest `build/tail-phase3-find-preview/Duckpad.app` preview.
Its bundle/general/packaged-language checks also pass; the colour-only evidence
above is retained as the original phase-3 run.
