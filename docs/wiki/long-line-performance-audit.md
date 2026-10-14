# Long-line performance audit

## Released 0.10.3 baseline

The motivating fixture is a 9,184,692-byte ASCII JSON file with one physical line.
The target is at most 50 ms from a native committed input call through Cocoa
input-manager queries, status calculation, synchronous drawing and a Core
Animation transaction flush. File loading precedes the measurement. These are
application rendering timings, not hardware key-to-photon measurements.

Four separate full Release runs rotated the first edit among the beginning,
middle, end and longest string. All 3,072 events passed; the maximum was
42.67575 ms. First input at those positions took 36.547458, 21.389667, 18.242499
and 19.320375 ms respectively. Original input bytes were never saved or modified.

Shared improvements cover ASCII coordinate queries, cached line comparisons,
monospaced ASCII layout, wrapping, brace matching and batched native input.
JSON additionally reuses byte-verified syntax and folding results on complete
single physical lines from 64 KiB through 32 MiB. Unicode shaping, tabs,
proportional/italic fonts, representations and bidirectional layout retain their
existing correctness paths. The JSON cache limit is not a total-memory limit.

## Other formats

The audit uses an Apple M4 Pro on macOS 27.0.1. Synthetic fixtures repeat the
following units to approximately 9.18 MB; XML has an enclosing `root` element.
These are stress cases, not representative average project files.

| Fixture | Lexer | Repeated unit |
| --- | --- | --- |
| Plain text | `null` | `event payload abcdefghijklmnopqrstuvwxyz 0123456789 ` |
| Minified JavaScript | `cpp` | `function f(x){return x+1;}const a=f(42);` |
| Minified CSS | `css` | `.item{color:red;padding:4px;margin:0;display:block;}` |
| Minified XML | `xml` | `<item id="123"><name>payload</name><value>42</value></item>` |
| Korean text | `null` | `한글 입력 성능 확인 가나다라마바 사아자차카타파하 ` |
| Multiline log | `null` | `2026-10-14 INFO request completed id=42 duration_ms=10 payload=abcdefgh` followed by LF |

The diagnostic quick mode measures 240 operations per completed fixture: eight
insert/delete pairs and four burst characters at six positions, plus selection
replacement, punctuation, 256-character input and Undo/Redo. It still checks the
50 ms **maximum**, never only p95, and verifies exact bytes after restoration.
Lexers are selected directly with folding, wrapping and brace matching enabled;
non-JSON keyword lists are empty. This isolates the engine stress path rather
than reproducing every language preference.

| Fixture | Bytes | Maximum latency | 50 ms budget | Exact Undo/Redo |
| --- | ---: | ---: | --- | --- |
| Plain text | 9,184,656 | 45.95 ms | PASS | PASS |
| Minified JavaScript | 9,184,680 | 237.91 ms | FAIL | PASS |
| Minified CSS | 9,184,656 | 154.97 ms | FAIL | PASS |
| Minified XML | 9,184,661 | 171.84 ms | FAIL | PASS |
| Korean text | 9,184,680 | 322.15 ms | FAIL | PASS |
| Multiline log (127,566 lines) | 9,184,680 | 11.06 ms | PASS | PASS |

All six runs completed sequentially, totaling 1,440 operations. The nonzero
benchmark exits for four formats reflect latency failures, not byte-integrity
failures. In the Korean fixture's first end-position input, surrounding-text
queries alone took 121.85 ms; selected-range, first-rectangle and status queries
added another 83.81 ms. Repeated Unicode coordinate scans remain a significant
cost in addition to layout. No claim is made that all large files meet 50 ms.

## Reproduction

Build with `swift build -c release --product DuckpadPerformanceBenchmark`.
Run the resulting executable with `--long-line <UTF-8-file> [lexer]`; the default
lexer is `json`. Set `DUCKPAD_LONG_LINE_FIRST_POSITION` to `start`, `middle`,
`end` or `long-string` for independent cold-first-input runs. Set
`DUCKPAD_LONG_LINE_QUICK=1` only for the shorter diagnostic matrix, not the full
JSON acceptance run. Fixtures are loaded into isolated in-memory documents and
are never saved.

## Follow-up work identified in 0.10.3

- Minified JS/CSS/XML: their lexers still scan a physical line to recover syntax
  and folding state. The JSON cache cannot safely be shared without accounting
  for each language's lexical state and lookahead rules.
- Very long Unicode/tab-containing lines: coordinate conversion and shaping
  retain scans skipped by the ASCII fast path. Incremental character/column
  indexes and bounded layout invalidation are follow-up work.
- Large multiline files: physical line length must be measured separately from
  total file size; short lines avoid the same repeated full-line work.

The patch preserves rendering/editing correctness and reports remaining slow
cases rather than silently disabling syntax, wrapping or editing features.


## Performance-gate follow-up (2026-10-14)

The follow-up fixes the measured lexer, Unicode-coordinate and layout bottlenecks
and expands the matrix to dense JSON, tabs, emoji, combining characters and
ordinary multiline JavaScript/CSS/XML. Each generated fixture is approximately
9.18 MB. The original reported JSON is an additional read-only input.

Implementation:

- Sparse UTF-8/UTF-16/scalar/tab-column checkpoints in the existing gap buffer
  replace repeated prefix scans. Insert/delete/Undo/Redo repair local checkpoints;
  arbitrary byte edits preserve the upstream malformed-UTF-8 semantics.
- Wrapping reads cached line bytes; common UTF-8 widths are inlined. Measured
  monospaced ASCII layout supports normal tabs. Layout avoids clearing a full
  positions array immediately before overwriting it. Shaping remains enabled for
  Unicode and unsupported font/style/representation combinations.
- Representation lookup skips its tree search for Unicode scalars whose leading
  key byte has no multi-byte representation. Default invalid-byte representations
  previously forced this search for every ordinary Unicode scalar. Custom entries,
  line separators and canonical key aliases retain their existing behavior.
- CPP/CSS/XML use their original lexer on a worker snapshot for requested spans
  or boundary physical lines of at least 1 MiB. Exact bytes and configuration
  must still match before applying styles, folds and line state. Jobs coalesce;
  closing/replacing a document cannot apply an obsolete result. Fold/line-state
  application yields in approximately 2 ms slices and validates bytes/configuration
  again between slices. A large request
  makes that lexer asynchronous until the document falls below 1 MiB or an
  unsupported private/substyle operation requires the synchronous delegate.
- Async styles invalidate wrapping, refresh overlays and retry fold recovery.
  Collapse All survives pending styling; Expand All cancels it, including through
  the controller/menu capability path. Reload/shared-document changes cancel
  old pending commands. Deferred Collapse All also runs in short slices, preserving
  native header flags, visibility, caret and viewport semantics. The benchmark
  waits for both asynchronous styling and all deferred folding slices.
- Release C++ uses speed optimization (`-O3`) rather than the backend's `-Os`.
  No fast-math or new dependency is used.

The 50 ms input budget includes native edits, Cocoa selected-range/surrounding-text/
rectangle queries, status, drawing and `CATransaction.flush()`. It also checks
main-loop stalls between inputs and while asynchronous styling completes. Total
background highlighting latency is reported separately: it can exceed 50 ms
without blocking input. The timer starts at committed native input, not physical
keyboard activation or IME candidate composition. Loading precedes measurement.

Reproduce the full matrix (768 input/edit operations per fixture, six positions):

```sh
scripts/run_long_line_performance.py --output /tmp/duckpad-gates
```

Use `--json-fixture <path>` to add the original file without modifying it;
`--positions start,middle,end` rotates the first edit in separate processes.
`--style-state pending` tests immediate typing during initial styling;
`--style-state recoloured` requests Collapse All, waits for full styles/folds,
expands and then measures input, including ordinary multiline source.
`--quick` uses 240 operations and is only the shorter diagnostic pass.
JSON reports retain fixture hashes, platform, sample counts and every run's log.
Samples exceeding 40 ms additionally log wall time, main-thread CPU time and
input/query/drawing phases. These diagnostics do not change the 50 ms wall-time
gate. CPU timing ends a few microseconds after the wall-time sample; wall minus
CPU includes scheduler and AppKit/OS waits and cannot identify their cause alone.
Run sequentially on an otherwise idle machine; do not build or run tests alongside
latency gates. Maxima, not only percentiles, decide pass/fail.

Correctness reproduction:

```sh
scripts/test_native_performance.sh
swift build --target DuckpadEditorAdapterTests
```

The second command compiles the adapter tests. With the current Command Line
Tools/Xcode build layout, run the compiled suite serially using:

```sh
/Library/Developer/CommandLineTools/usr/libexec/swift/pm/swiftpm-testing-helper \
  --test-bundle-path .build/out/Products/Debug/DuckpadEditorAdapterTests.xctest/Contents/MacOS/DuckpadEditorAdapterTests \
  --testing-library swift-testing --no-parallel
```

Add `--filter FoldingEditorAdapterTests` for the targeted folding run.

The native checks compare a million deterministic byte sequences with upstream
UTF-8 classification and randomized gap-buffer edits with scalar/column walks.
They compare asynchronous styles, folds and line states with fresh upstream
lexers, including edits during jobs, configuration changes and destruction.
AppKit tests compare style-dependent wrapping/caret positions and deferred fold
commands across cancellation, reload and shared-document replacement.
`tests/native/UnicodeLayoutComparison.mm` emits deterministic geometry for
comparison with a separately built baseline: 144 combinations of Unicode,
malformed bytes, tabs, fonts and wrap modes matched 0.10.3.

### Recorded validation

[Machine-readable results](long-line-performance-gates.json) preserve successful
and failed runs, including their hashes; retests do not erase earlier failures.
The product changes include the final representation lookup optimization. The
`diagnostic-current` and `acceptance-last` groups add timing logs only.
The baseline original file was 9,184,692 bytes; the current read-only snapshot is
9,184,752 bytes, SHA-256
`fcef12340548b4bea254ad9de950b9a594d8f42d23aa1ddcad6ee8f9488aaa60`.
The benchmark never saves this source file. Each report group identifies its
temporary raw-log directory and log hashes; the repository evidence contains summary metrics
and the slow diagnostic samples, not copies of the source documents.

The first full 14-fixture run after the representation optimization
(`final-current`, 768 events each) recorded:

| Fixture | Maximum ms | 50 ms gate |
| --- | ---: | --- |
| Dense JSON | 42.33 | PASS |
| Minified JavaScript | 33.40 | PASS |
| Minified CSS | 57.48 | FAIL |
| Minified XML | 38.88 | PASS |
| Plain text | 28.91 | PASS |
| Korean | 39.23 | PASS |
| Tabs | 40.03 | PASS |
| Emoji | 71.71 | FAIL |
| Combining characters | 54.79 | FAIL |
| Multiline log | 15.65 | PASS |
| Multiline JavaScript | 37.34 | PASS |
| Multiline CSS | 43.31 | PASS |
| Multiline XML | 26.05 | PASS |
| Original JSON, read only | 42.55 | PASS |

Additional observations:

- Three full combining-character runs with first input at start/middle/end
  passed 2,304 events; maxima were 45.53, 35.28 and 36.41 ms.
- Six pending-styling and three recoloured/folded quick runs passed 2,160 events;
  the largest main-loop stall was 46.30 ms. Earlier unsliced fold/line-state
  application stalled for 241–365 ms; deferred Collapse All stalled for 169–203 ms.
- Eight quick cold-position runs passed seven fixtures/positions; Korean with
  middle-first input exceeded the budget at 58.19 ms.
- Four full diagnostic retests also exceeded wall-time gates: CSS 62.49 ms,
  emoji 65.44 ms, combining characters 99.92 ms and Korean 66.21 ms. All 61
  samples logged above 40 ms used less than 50 ms of main-thread CPU. The worst
  combining sample used 34.07 ms of CPU during 99.92 ms of wall time. The worst
  CSS sample used 27.13 ms CPU, with 35.95 ms in drawing/transaction flush.
- Independent compiler/test processes and macOS indexing/media-analysis processes
  were concurrently active during these retests. Their load is a confounder,
  not proof that all extra time came from external scheduling. The strict wall
  gate remains failed for these runs; a quiet-machine acceptance run is required.

The final full repeat (`acceptance-last`, 10,752 events) began after the observed
parallel compilers finished. It passed 11 of 14 fixtures. First input in all 14
fixtures remained below 50 ms (largest approximately 48.53 ms; provided JSON
approximately 36.18 ms), but subsequent events still failed:

| Fixture / slowest event | Wall ms | Main-thread CPU ms | Drawing/flush wall ms |
| --- | ---: | ---: | ---: |
| Tabs / Undo | 52.83 | 37.15 | 17.64 |
| Combining characters / insertion | 65.63 | 32.54 | 11.13 |
| Provided JSON / backspace | 67.26 | 37.44 | 44.99 |

macOS media analysis and other processes were still active. This repeat is not
an isolated-machine result and is **not a passing acceptance run**. Across all
52 recorded runs, 30,960 input events were measured and 11 runs failed the wall
gate. At that stage, correctness validation passed but stable 50 ms acceptance
remained unresolved. The additional work below addresses measured layout costs. No threshold
was relaxed, and CPU time was never substituted for elapsed latency.

Correctness passed separately from latency:

- Native regression harness: approximately 1.38 million checks, including
  malformed bytes, Unicode/UTF-16/tab coordinates, arbitrary gap-buffer edits,
  Undo/Redo and exact upstream lexer results. Representation checks cover custom
  Unicode, default line separators, replace/clear/reset and NUL key aliases.
- ASan/UBSan: all eight changed native implementation units instrumented; native
  correctness and AppKit layout/folding harnesses passed. Unchanged native units
  and Lexilla were linked from Release objects and were not instrumented.
- All 144 geometry combinations matched the baseline after the final native edit.
- Editor adapter tests: 330 tests in 34 suites passed with `--no-parallel`.
  The 31 folding tests passed again after the final fallback-notification edit.
  Parallel AppKit execution had timing/interference failures; use serial execution.
  A separate whole-package test build remains blocked by an unrelated
  `MenuPresentationSpy` Swift concurrency compilation issue.
- Independent review found no remaining Blocker/Major issue. Build warnings about
  Command Line Tools framework search paths and native harness cursor resources
  did not prevent compilation or execution.

This matrix is a regression gate for these fixtures and this machine. It does
not establish a bound for arbitrary file sizes, all Lexilla languages, fonts,
bidirectional text, plugin work, IME composition latency or physical display time.


## Additional layout headroom

The next profiling pass measured real repeated work: median JSON copy/width
calculation was 8.845 ms, tabbed text 19.475 ms, and combining-character segment
construction 13.282 ms. Exact-grid uniform advances, integral ordinary tab
columns and uniform-style UTF-8 segment scanning reduced those stages to
4.534, 10.955 and 5.552 ms respectively. These are diagnostic stage medians,
not acceptance maxima; temporary instrumentation was removed before acceptance.

A new native harness compares every position bit and wrap boundary against the
scalar path in 160 metric/style/tab cases, plus Unicode segment boundaries and
representations. Extreme metrics exposed an existing integer overflow in tab
calculation; tab numbers now stay in floating point and custom-stop conversion
is bounded. An additional 40,000 normal-coordinate comparisons preserve the
legacy formula. Final Release and ASan/UBSan runs passed 1,449,620 width,
segment and tab checks, the existing approximately 1.38 million native checks,
and AppKit layout/folding checks. Sanitizers used halt-on-error, instrumenting
the eight changed implementation units. All 144 baseline geometry cases matched.

The first full run after the layout optimizations (`headroom-final`) passed
12/14 fixtures: tabs 32.334 ms, combining characters 35.343 ms and the original
JSON 37.359 ms. Korean (130.506 ms) and emoji (87.859 ms) failed while external
compiler processes were active; those failures are retained in the evidence.
The subsequent tab-overflow fix is included in the final acceptance runs below.

### Final full matrix

`headroom-acceptance` passed all 14 fixtures and 10,752 input events in one
sequential full Release run. The largest measured gate was 42.701125 ms;
the largest first-input phase total was approximately 41.79 ms. File loading
precedes input measurement. Exact Undo/Redo restoration passed for every fixture.

| Fixture | Maximum ms | 50 ms gate |
| --- | ---: | --- |
| json | 30.565 | PASS |
| javascript | 33.826 | PASS |
| css | 29.304 | PASS |
| xml | 33.443 | PASS |
| plain | 22.755 | PASS |
| korean | 33.700 | PASS |
| tabs | 35.421 | PASS |
| emoji | 41.791 | PASS |
| combining | 33.528 | PASS |
| log | 13.631 | PASS |
| multiline-javascript | 38.585 | PASS |
| multiline-css | 42.701 | PASS |
| multiline-xml | 26.928 | PASS |
| provided-json | 39.492 | PASS |

The pending-styling matrix initially recorded one XML backspace at 109.331 ms
(17.275 ms of main-thread CPU). That failed run is retained; a complete six-case
repeat passed. Recoloured/folded JS/CSS/XML also passed all three cases, with a
46.684 ms maximum main-loop stall. A passing later run does not erase earlier
wall-time failures or establish a hard real-time guarantee under arbitrary load.

Cold middle/end-first runs for Korean, tabs, emoji, combining characters and the
original JSON passed all 10 cases (2,400 events), maximum 37.815 ms.
The final accepted groups total 33 runs and 15,312 input events, all within
50 ms; maximum including idle/styling was 46.684 ms. All 105 recorded runs
(58,464 events), including 14 historical/earlier failed runs, remain in
`long-line-performance-gates.json`. The original input file still matches its
recorded SHA-256 and was never saved. No timing threshold or feature was disabled.

Reproduce the full matrix with:

```sh
python3 scripts/run_long_line_performance.py --json-fixture /path/to/rea-rgloader32.json --output /tmp/duckpad-full-gates
scripts/test_native_performance.sh
```

Use separate sequential runs with `--style-state pending` (six JS/CSS/XML
fixtures), `--style-state recoloured` (three multiline fixtures), and
`--positions middle,end` (Unicode/tabs/original JSON). The additional modes used
`--quick`; the full 14-fixture acceptance did not. Independent final review found
no Blocker/Major issues. Whole-package Swift compilation remains subject to the
unrelated `MenuPresentationSpy` limitation recorded above; this follow-up's new
native Release, sanitizer and geometry validations passed.
