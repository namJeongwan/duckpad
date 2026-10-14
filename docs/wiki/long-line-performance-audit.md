# Long-line performance audit — 0.10.3

## Scope and measurement

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

## Remaining work

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
