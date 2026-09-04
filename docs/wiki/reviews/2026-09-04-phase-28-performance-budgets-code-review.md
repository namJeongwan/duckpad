# Phase 28 native performance budgets — independent code review

- **Reviewer:** `/root/phase1_code_review` (independent; no implementation)
- **Date:** 2026-09-04
- **Initial candidate:** `128e6ab135355d02bfe0e86e61125d337fac9e2133700aa5d459e4cd9467e4dd` (rejected and abandoned)
- **Intermediate candidate:** `56eb4bfc6b3204e585a61b584c170f02fc31ed467f8a05e91d9da1e98ed0fa3e` (rejected and abandoned)
- **Final remediation candidate:** `f5cfd2ada2772ff04cb01b940f5fbb5f574fb0381e8e1179d3326519475258a5`
- **Reviewed tree:** `e5e7c6b573d8af7bcf6ab860d8c93c33491b0bce`
- **Final verdict:** **APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor**

## Scope

Reviewed the exact eight staged paths: the Release benchmark executable and
budget JSON, SwiftPM target declaration, packaged warm-ready hook, isolated
runner, Phase 27 delivery metadata, Phase 28 ADR, and wiki index. Review covered
semantic representativeness, clock/aggregation methodology, fail-closed budget
enforcement, temporary-path and process lifecycle safety, user-state isolation,
packaging exclusion, and reproducibility.

The user-owned unstaged `docs/wiki/04-implementation-foundation.md`, untracked
`scripts/vendor_scintilla_5_6_6.sh`, all README paths, and ignored Notepad++ were
excluded and preserved. No product/source/test/work-document or staged byte was
modified by this reviewer; only this review record and the index reviewer row
and work log are changed after the verdict.

## Findings

- **P28-01 Major — CLOSED** — `Benchmarks/DuckpadPerformanceBenchmark/BenchmarkMain.swift:211-246`: initial `open_100mb` timed only direct in-memory bridge loading and could pass while file read, decode, workspace publication, or adapter installation regressed; time a real cache-warm 100 MiB file through `LocalTextFileStore` → `TextFileCodec` → workspace transaction → Scintilla and verify the final authoritative byte count. Final bytes implement the complete pipeline and freeze its semantically new budget at 1,500 ms.
- **P28-02 Major — CLOSED** — `scripts/run_performance_benchmarks.sh:21-65`: initial warm launches had no deadline, so a readiness regression hung the release gate instead of producing a bounded failure; wrap each exact forked app PID in a watchdog that TERM/KILLs, waits, and returns a typed nonzero status. Final bytes use a 10-second Perl watchdog, and the independent 20-second-child probe returned 124 in 11 seconds with no child left behind.
- **P28-03 Major — CLOSED** — `scripts/run_performance_benchmarks.sh:14-33`, `Sources/DuckpadApp/DuckpadMain.swift:73-79`: initial runner isolated settings/recovery/workspace/extension paths but left `LocalTextFileStore` pointed at the real default bookmark archive, contradicting the no-user-state contract; inject a dedicated temporary bookmark archive. Final bytes add `DUCKPAD_DOCUMENT_BOOKMARKS_FILE` and keep every mutable app authority under the owned temporary root.
- **P28-04 Major — CLOSED** — `Sources/DuckpadApp/DuckpadMain.swift:811-827`: the intermediate warm launch still evaluated `NSDocumentController.shared.recentDocumentURLs`, so timing read real per-user state despite the isolated archives; branch to an empty recent list before touching `NSDocumentController` and prove zero reads in the ready marker. Final bytes do so, and the runner accepts only `DUCKPAD_PERF_READY=1 RECENTS=0`.

No finding remains open.

## Independent evidence

- Candidate recomputation: parent `20855687cb4138a609cca24f528ab41d4c4167f6`, tree `e5e7c6b573d8af7bcf6ab860d8c93c33491b0bce`, diff SHA-256 `e7b8ccf56c397e8a61d28656fd09ab12583aeb65e551deeda5b0971b8797e2ab`, message SHA-256 `6948436fcd9293916f37f451e9424033e01cbd2de63f951d60835358e50c25fd`: PASS.
- `git diff --cached --check` and `bash -n scripts/run_performance_benchmarks.sh`: PASS; exact stage was eight paths with no gitlink, README, ignored reference, build/cache, doc04, or vendor-script inclusion.
- Full independent final-candidate Release runner: 5/5 PASS — isolated-recents warm maximum 498.210 ms, typing p95 0.019666 ms with workspace revision 330, complete 100 MiB open 946.953917 ms, 200-tab reflow p95 0.001709 ms, and 2,000-file folder-search maximum 262.211584 ms.
- A deliberate 751 ms warm value completed the remaining probes, emitted JSON `status: fail`, and exited 1; malformed warm input exited 2.
- The exact watchdog body run against `/bin/sleep 20` exited 124 after 11 seconds and left no matching child process.
- Static packaging inspection confirms `build_macos_app.sh` builds/copies only `DuckpadApp` and `DuckpadPluginRuntime`; the benchmark executable and budget resource are not shipped in `Duckpad.app`.
- Builder results are supporting evidence only: current full runner 5/5, Debug/Release app resource tests 1/1 each, warning-free Release benchmark build, parity structural PASS with release false, and deliberate failure probes PASS.

## Exact manifest

For the seven-path product/work-document manifest (wiki index and this review
record excluded), the sorted NUL-delimited path digest is
`b4f56b16aab26885e0e3db102f0fc720ed7e7ea67274d71dd6169fbcdd25b3e3`.
The sorted `path NUL bytes NUL` digest is
`738fd08546e15079fa46531a2d7b745a49c3de1c320ddc26c1a7894ee8d8eddc`.

## Verdict

**APPROVED — CONTENT REVIEW; 0 Blocker, 0 Major, 0 Minor.** The five budgets
exercise the declared production boundaries, fail nonzero without being
silently loosened, isolate mutable state, and bound failed process startup.
Adding this review/index evidence changes the candidate identity, so an exact
refreeze and separate receipt verification are required before commit.

## Agent Work Log

- Recomputed all three candidates and inspected every staged hunk plus file-open,
  packaging, session, search, and layout implementations used by the probes.
- Independently identified the direct-load, unbounded-launch, bookmark-isolation,
  and system-recents isolation defects; rejected both superseded candidates.
- Ran the frozen full runner and adversarial exit/watchdog probes, recomputed
  the seven-path manifest, and changed evidence files only.
