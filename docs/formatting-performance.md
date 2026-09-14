# Formatting performance probes (2026-09-14)

Local native arm64 Release measurements of the current formatter implementation.
Each workload ran in two fresh benchmark processes, each performing one initial
format and three formats after Undo. Thus each row has two initial measurements,
six repeated measurements, and six Undo measurements. Ranges below are observed
minimum–maximum times, not latency guarantees or percentile estimates.

The benchmark uses DocumentFormattingUseCase, BundledPrettierFormatter, the native
Scintilla adapter, workspace callbacks, and the bundled language definition's
lexer/keywords/folding configuration. It includes formatter execution, diffing,
and native text application; it does not measure visible frame presentation.
Undo timing includes the read-back check that the original UTF-8 bytes returned.

| Workload | Input bytes | First format (ms) | Repeated format (ms) | Undo (ms) | Repeated engine only (ms) |
|---|---:|---:|---:|---:|---:|
| JSON, 32 KiB | 32,777 | 166–197 | 44–62 | 18–25 | 12–25 |
| YAML, 32 KiB | 32,901 | 261–266 | 25–36 | 10–11 | 20–32 |
| SQL, 32 KiB | 32,860 | 307–314 | 74–84 | 22–24 | 40–52 |
| JSON, 256 KiB | 262,242 | 317–320 | 143–165 | 44–53 | 52–74 |
| YAML, 256 KiB | 262,180 | 472–493 | 151–195 | 52–56 | 126–169 |
| SQL, 256 KiB | 262,350 | 643–646 | 399–416 | 61–64 | 293–306 |

All 12 process runs completed with exact Undo restoration, exact recovery bytes,
and actual engine idempotence checked by formatting the result again outside the
revision cache. Unchanged-revision formatting took 0.017–0.046 ms and skipped the
engine in all runs. The Release benchmark build and `git diff --check` passed.

## Workload interpretation

- JSON: compact arrays of 263 / 2,090 small records containing numbers, booleans,
  arrays, and Korean labels. Outputs grew to 48,565 / 387,650 bytes.
- YAML: 223 / 1,767 block sequence records with those field types, excessive
  alignment spaces, and flow-style tag arrays. Outputs were 30,448 / 242,743 bytes.
- SQL: 124 / 990 SELECT statements with JOIN, WHERE, aggregation, GROUP BY,
  HAVING, ORDER BY, comments, and Korean string literals. The default `sql`
  dialect was used. Outputs were 37,943 / 302,939 bytes.

Byte sizes are similar; record counts, syntax structure, and edit counts are not
identical. These do not establish that one language is inherently faster. The
earlier user workflow JSON contained large embedded strings and formatted in
93–97 ms after warmup; this synthetic JSON takes 143–165 ms at a similar input
size. Content shape and output expansion materially affect runtime.

For the 256 KiB SQL batch, about 294–305 ms of the 399–416 ms repeated format was
inside the formatter engine. YAML's repeated engine time was 126–169 ms. The
compact JSON bundle reduces JSON startup only; these YAML/SQL probes load the
full bundle. Database execution, other SQL dialects, long-term memory behavior,
and direct comparisons with Zed or VS Code were not measured.

## Reproduction

Run commands from the task worktree. Fixtures contain generated data and are
copied into an isolated temporary workspace by each benchmark run.

```sh
python3 scripts/formatter/generate-benchmark-fixtures.py /tmp/duckpad-format-language-fixtures
swift build -c release --product DuckpadPerformanceBenchmark
.build/release/DuckpadPerformanceBenchmark --format-json /tmp/duckpad-format-language-fixtures/records-256k.json
.build/release/DuckpadPerformanceBenchmark --format-yaml /tmp/duckpad-format-language-fixtures/records-256k.yaml
.build/release/DuckpadPerformanceBenchmark --format-sql /tmp/duckpad-format-language-fixtures/records-256k.sql
```

Repeat with `records-32k` for the smaller workloads. Run processes sequentially to
avoid CPU contention affecting results. This probe extends benchmark tooling;
it does not change application formatting behavior.
