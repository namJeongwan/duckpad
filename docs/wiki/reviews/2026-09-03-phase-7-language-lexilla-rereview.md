# Phase 7 P7-01 Independent Remediation Re-review

> Status: **APPROVED — CONTENT REVIEW**
>
> Date: 2026-09-03 (Asia/Seoul)
>
> Reviewer: `/root/phase1_code_review`
>
> Commit authorization: **not granted; exact-candidate receipt remains required**

## Scope

Focused re-review of P7-01 from `2026-09-03-phase-7-language-lexilla-code-review.md` only. The remediation changes are `Sources/DuckpadApplication/LanguageService.swift`, `Sources/DuckpadPresentation/DuckpadWindowController.swift`, `tests/DuckpadApplicationTests/LanguageWorkspaceUseCaseTests.swift`, and `tests/DuckpadPresentationTests/TabFlowLayoutTests.swift`. No new acceptance criteria were added. Pre-existing `docs/wiki/04-implementation-foundation.md` and `scripts/vendor_scintilla_5_6_6.sh` remained excluded and preserved; reviewed source/test was not modified, staged, or committed by the reviewer.

After the independently reviewed upstream-whitespace policy correction, the complete Phase 7 product/acceptance manifest is 189 paths: the previously approved 188 plus root `.gitattributes`. Its sorted path-list SHA-256 is `c1dd9781d9212530d35290250def28264272308985538bf558830e52ea84f840`; current path+byte SHA-256 is `f17f16b381359b6c73e8d5a9395d2ddfd372da1e82d43a404b2d5fd45fa234be`.

## P7-01 Closure Evidence

- `LanguageServiceState.unavailableManual(requestedID:fallback:)` preserves the missing typed ID separately from the safe effective fallback.
- `refreshActive()` resolves the detector's Plain Text fallback, applies the bundled `null` lexer, then publishes `unavailableManual` when the persisted manual ID is absent. It does not call a workspace mutation or rewrite the override.
- The hosted controller renders `Unavailable language: removed-language · using Plain Text` in warning color. The Language menu retains Auto and available definitions, and does not fabricate the removed ID as an actionable choice.
- Explicit Auto is the only tested clearing action: it durably removes the manual override, re-detects Python from the shebang, clears the warning, and leaves text and buffer revision unchanged.
- The Application test preserves `.manual(removed-language)` through unavailable refresh and proves the configured fallback is language `text`/lexer `null` before explicit Auto.
- The hosted test compares the entire recovered session, active buffer metadata, UTF-8 text snapshot, and mutation counter before/after unavailable presentation. Existing real Scintilla tests continue proving lexer/theme changes preserve text, revision, undo state, and avoid recovery edit notifications.
- No fallback branch invokes line comment or another text-edit command; `toggleLineComment()` remains disabled unless state is `.ready`.

## Validation

- Focused language/P7-01 suite: PASS 20/20.
- Debug full suite: PASS 152/152.
- Release full suite: PASS 152/152.
- Production language smoke: PASS, `Duckpad language smoke ready: Lexilla 5.5.3 Swift/Python + dark palette`.
- Official Lexilla subset/license/version remains byte-identical to the independently downloaded archive; four interface headers remain byte-identical to pinned Scintilla 5.6.6.
- `git diff --check`: PASS; staged paths: 0.

## Upstream Whitespace Policy Correction

- Abandoned candidate `00788bcd…` is not staged or committed; the real index is empty. `git config --show-origin` finds no local/global `core.whitespace` or `apply.whitespace` override.
- Root `.gitattributes:L4` matches only `/Vendor/Lexilla/5.5.3/**` and assigns only `whitespace=-blank-at-eol,-blank-at-eof,-space-before-tab`. `text`, `eol`, `filter`, `ident`, and `working-tree-encoding` remain unspecified, so it cannot normalize or transform source bytes.
- `git check-attr` confirms the exact versioned subtree gets those three settings; Duckpad source, another Lexilla version, sibling vendor paths, and `.gitattributes` itself remain `unspecified`.
- Adversarial `git apply --check --whitespace=error-all` probes PASS: trailing whitespace, space-before-tab, and a new blank line at EOF are accepted only at the versioned upstream path; equivalent nonvendor patches fail with the expected diagnostics.
- A fresh temporary root ran the current `scripts/vendor_lexilla_5_5_3.sh`; all 165 generated files, including updated provenance, match the current vendor subtree byte-for-byte. The script still verifies official archive SHA-256 `4d9e64263c337034a06f9c67f330c605764cac02aee83c06f6c21f9527a71628` and does not read Git attributes.
- An alternate isolated index containing the eventual 192 paths (189 product/acceptance + original review + this re-review + index) passes `git diff --cached --check`; the real index remains unchanged and empty.
- P7-01 source/test SHA-256 values remain unchanged from content approval (`2e5557…`, `72d878…`, `f7d4eb…`, `5afc92…`), and the post-policy focused language suite passes 20/20. The policy/documentation correction cannot affect compiled behavior.

## Findings

### Blocker

None.

### Major

None. P7-01 is closed.

### Minor

None.

## Verdict

**APPROVED — CONTENT REVIEW.** Findings: **0 Blockers, 0 Majors, 0 Minors**. P7-01 remains closed. The exact-version whitespace policy suppresses only three diagnostics inherited from official Lexilla, preserves all 165 reproduced bytes, leaves nonvendor checks strict, and introduces no filter/EOL/security scope. Exact staged candidate verification and a canonical signed receipt are still required before commit authorization.

## Agent Work Log

| Field | Record |
| --- | --- |
| Agent | `/root/phase1_code_review` — independent Phase 7 P7-01 re-reviewer |
| Skill | `caveman-review`; no open finding remained. |
| Scope | P7-01 closure plus the subsequent exact-version Lexilla whitespace-policy correction; no new product criteria. |
| Static work | Traced restored manual ID through detector, service fallback state, controller status, menu, explicit Auto persistence, and no-edit paths. |
| Dynamic work | Focused 20, debug/release 152-test runs, production smoke; fresh 165-file reproduction; attribute-scope/adversarial whitespace probes; isolated 192-path cached check; product manifest digests. |
| Files changed | This re-review document and the document-00 Agent Work Log/index entry only. |
| Reviewed source/stage/commit | None. |
| Verdict | APPROVED — 0 Blocker, 0 Major, 0 Minor. |
