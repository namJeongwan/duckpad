# Phase 28 — Native performance budgets

Status: **Content approved; exact receipt pending**

## Decision

Duckpad's release performance gate is a versioned Release-build benchmark, not
an informal stopwatch result. The gate covers the five workflows required by
the roadmap: warm application readiness, committed typing latency, 100 MiB
Scintilla loading, 200-tab reflow, and recursive folder search.

The canonical budgets live in
`Benchmarks/DuckpadPerformanceBenchmark/performance-budgets.v1.json`. A release
candidate fails when any measured value exceeds its frozen maximum; changing a
maximum is a reviewed performance-policy change and cannot be done during final
release validation merely to turn a failure green.

## Fixtures and aggregation

- Warm launch builds and verifies a native-architecture sandboxed `.app`, runs
  one priming launch, then takes the maximum of five complete process invocations
  through completed session startup and an editable Scintilla window.
- Typing records the p95 of 300 one-byte committed Scintilla edits after 30
  warm-up edits.
- Large-file open reads an exact cache-warm 100 MiB ASCII fixture with 80-byte
  lines through the production file store, codec, workspace transaction, and
  Scintilla install, then verifies the editor's authoritative byte count.
- Tab reflow records p95 across 500 layouts of 200 tabs at four representative
  workspace widths and verifies every frame/row result is present.
- Folder search records the maximum of three cache-warm descriptor-relative
  searches over 2,000 files in 20 directories (about 16 MiB), requiring exactly
  one result in every file with no truncation.

`scripts/run_performance_benchmarks.sh` owns the isolated temporary state,
builds the release artifacts, gathers the warm launches, and invokes the
benchmark executable. The executable validates the exact metric inventory,
emits a machine-readable JSON report, and exits nonzero on a budget failure.
Every launch has a 10-second watchdog that terminates only its exact child PID.
Settings, recovery, document bookmarks, workspace roots, extensions, and
extension policy all resolve inside the temporary root; fixtures are removed
after every run. The performance menu receives an empty recent-document list
without evaluating `NSDocumentController` system recents, and the ready marker
asserts zero system-recent reads. No user application state is read or written.

## Initial reference profile and budgets

The initial baseline was established on 2026-09-04 on an Apple Silicon MacBook
Pro (Apple M4 Pro, 14 logical processors, 48 GiB) running macOS 26.5.1. The
frozen maximums are:

| Metric | Maximum |
| --- | ---: |
| Warm launch ready, max of five | 750 ms |
| Typing latency p95 | 0.5 ms |
| 100 MiB open | 1,500 ms |
| 200-tab reflow p95 | 0.05 ms |
| Folder search, max of three | 750 ms |

These thresholds include meaningful headroom for machine noise while remaining
far above the measured baseline. CI on slower supported hardware must publish
its own observed report but may not rewrite this policy without review.

The exact Release runner on that profile produced:

| Metric | Observed | Result |
| --- | ---: | --- |
| Warm launch ready, max of five | 394.334 ms | PASS |
| Typing latency p95 | 0.014375 ms | PASS |
| 100 MiB open | 920.378542 ms | PASS |
| 200-tab reflow p95 | 0.001625 ms | PASS |
| Folder search, max of three | 256.327375 ms | PASS |

The warm result includes complete process invocation and sandboxed app startup;
the application only emits its ready marker after session startup completes.
The runner also verifies the packaged app's resources, architecture,
entitlements, embedded XPC boundary, and signatures before timing it.

## Architecture and safety

The benchmark executable is a development product and is not copied into the
distributed app bundle. It calls the same public Application, Infrastructure,
Presentation layout, Scintilla bridge, and production regex paths as Duckpad.
The launch probe is gated by an explicit environment variable and terminates
with `_exit` only after startup readiness; ordinary application lifecycle is
unchanged.

Macros, README files, the ignored Notepad++ checkout, and user-owned unstaged
files remain outside this phase.

## Validation

- `scripts/run_performance_benchmarks.sh`: all five frozen budgets PASS and a
  schema-v1 JSON report is emitted.
- `swift build -c release --product DuckpadPerformanceBenchmark`: PASS without
  warnings.
- Debug/Release app-icon/resource tests: 1/1 PASS in each configuration; the
  standard parity validator remains structurally valid and reports
  `release_pass: false` because command evidence has not yet been attested.
- A deliberate `warm_launch_ready` value above 750 ms returns exit status 1 and
  emits report status `fail`; malformed arguments return status 2.
