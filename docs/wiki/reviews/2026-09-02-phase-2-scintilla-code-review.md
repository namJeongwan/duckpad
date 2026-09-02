# Phase 2 Independent Scintilla Code Review

> Status: **REJECTED — changes required**
>
> Date: 2026-09-02 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Content verdict: **REJECTED**
>
> Commit authorization: **not granted**

## Scope

Focused review of the current Phase 2 diff since `eee8143`: package files; official Scintilla 5.6.6 provenance, license, selected vendor bytes and Duckpad bridge; `DuckpadEditorAdapter`; production composition/window/fallback-boundary changes; new editor tests; `docs/wiki/05-scintilla-integration.md`; and the document-00 index entry. Unrelated governance and the modified document 04 were not reviewed. No reviewed source was modified, staged, or committed; this review document is the reviewer's only repository edit.

## Evidence

- Reviewed-file SHA-256 manifest digest: `4617a9dc9bb81d10d28b35ef007dd667a6db43a0b992049d9a0823e9bafcfe07`.
- Official `https://www.scintilla.org/scintilla566.tgz`: SHA-256 `b6b08598c68fac90990d010c1142494d707530602b5320753274d045c2b02189`, independently downloaded and extracted.
- Vendor comparison: 105 upstream subset paths present; 104 byte-identical and only `cocoa/ScintillaView.mm` differs with the documented cursor-resource patch (`40e215...` upstream, `d23aed...` patched). `License.txt` is byte-identical, `version.txt` is `566`, and all four packaged cursor PNGs are byte-identical to the archive.
- No changed path contains `notepad-plus-plus` or `Downloads`; no gitlink is present. The vendored byte inventory resolves to the official standalone archive. Identical upstream Scintilla files naturally also occur in the ignored Notepad++ checkout, but that checkout is neither a path nor build input.
- Debug build PASS; debug tests PASS 42/42.
- Release build PASS; release tests PASS 42/42.
- Fresh scratch dependency/build/test PASS 42/42.
- `DUCKPAD_SMOKE_EXIT=1 swift run --skip-build DuckpadApp`: PASS, `Duckpad smoke window ready with Scintilla 5.6.6`; production explicitly constructs and hosts `ScintillaEditorAdapter`.
- arm64 release executable: Mach-O arm64, minOS 13.0. Cross-built release executable: Mach-O x86_64, minOS 13.0.
- Existing real-view tests pass for ordinary UTF-8 edits, Hangul marked text, copy/paste, undo/redo, multiselection, wrap, focus/accessibility identifiers, buffer undo isolation, cursor resources, and a roughly 0.7 MB text load.
- Adversarial release bridge probe: replacing byte range `{1,1}` in UTF-8 `한` returns success and leaves invalid bytes `[237, 156]`; the same debug probe traps inside Scintilla.
- Adversarial overflow probe: after loading `x` at revision `UInt64.max`, committed user input changes visible content to `xy`, emits zero bridge edits, leaves revision at max, and merely disables further input.
- Large-edit probe through the production Swift adapter: one accepted end insertion cost 22 ms at 1 MB, 229 ms at 10 MB, and 1.124 s at 50 MB because every notification copied and decoded the complete document on MainActor.
- `git diff --cached --name-only`: empty.

## Findings

### Blocker

None.

### Major

`Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm:L104-L130`: 🔴 **P2-01 bug:** `replaceUTF8Range` checks only byte bounds, so a range can split a UTF-8 scalar; release accepts the edit and corrupts the document, while debug traps. Reject start/end positions that are not Scintilla UTF-8 character boundaries before `SCI_REPLACETARGET`, verify resulting UTF-8, and add split-start/split-end tests for 2/3/4-byte scalars with unchanged content/revision on failure.

`Vendor/Scintilla/5.6.6/bridge/DuckpadScintillaBridge.mm:L174-L199`: 🔴 **P2-02 bug:** revision exhaustion is checked only after Scintilla has already applied a user modification; at `UINT64_MAX` the bridge silently keeps changed text, publishes no edit, and disables input, leaving visible content outside Application/persistence state. Disable editing before a max-revision document can accept input or synchronously roll back the just-applied mutation, then test committed text, paste, undo, and IME at max revision for unchanged text and zero unpublished state.

`Sources/DuckpadEditorAdapter/ScintillaEditorAdapter.swift:L115-L130`: 🔴 **P2-03 architecture/performance:** every accepted incremental notification immediately calls `contentUTF8`, decodes the full document into `String`, and retains a duplicate snapshot on MainActor; a 50 MB one-byte edit blocked for 1.124 s. This defeats Scintilla's incremental large-document boundary and the document's claim of a “bounded snapshot.” Keep Scintilla as the live authority and update a bounded/checkpointed recovery representation off the keystroke path, or apply accepted deltas to an explicitly bounded recovery buffer; add a 10–50 MB typing latency/memory regression that fails the current O(document-size) path.

### Minor

None.

## Notes

- Four upstream Cocoa API deprecation warnings are non-blocking follow-up work as requested.
- Intel runtime, full VoiceOver/manual IME hardware coverage, and signed distributable `.app` validation remain manual/CI gates; cross-compilation and Mach-O/minOS inspection pass.

## Verdict

**REJECTED.** Findings: **0 Blockers, 3 Majors, 0 Minors**. Ordinary integration tests, provenance, packaging, and smoke checks pass, but malformed UTF-8 ranges can corrupt text, revision exhaustion can retain an unpublished edit, and the production keystroke path synchronously copies whole large documents. CONTENT APPROVED requires Blocker/Major zero; no commit is authorized.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent Phase 2 Scintilla reviewer |
| Skill | `caveman-review`; architectural rationale retained for P2-03. |
| Scope | Phase 2 Scintilla/package/adapter/composition/tests/document-05/index changes only; governance and document 04 excluded. |
| Static work | Read bridge, Swift adapter, production composition, tests, package boundary, vendor provenance/license, official patch, and requested docs; audited memory/lifetime, UTF-8/revision, IME, focus/accessibility, undo/multiselection/wrap, fallback, and architectures. |
| Dynamic work | Official tar acquisition/hash/subset comparison; debug/release/fresh 42-test runs; production smoke; arm64/x86_64 release builds and minOS inspection; invalid-boundary, overflow-user-edit, and 1/10/50 MB latency probes. |
| Files changed | `docs/wiki/reviews/2026-09-02-phase-2-scintilla-code-review.md` only. |
| Reviewed source/stage/commit | None. |
| Verdict | REJECTED — 0 Blocker, 3 Major, 0 Minor. |
