# Phase 29 — Frozen parity release evidence

Status: **In progress — parity reviewer onboarding candidate**

## Purpose

Phase 29 converts Duckpad's implemented product surface into candidate-bound,
independently signed evidence for the frozen 94-feature Notepad++ parity
baseline. A structural checker pass is not a feature claim: every non-Missing
state must resolve to typed evidence for the exact release candidate, and Full
requires both automated and manual evidence.

Macro recording and playback remain intentionally excluded from the Duckpad
roadmap. `C9.F02` therefore remains Missing and is not relabeled as N/A. The
90-percent score must be reached by real implementation elsewhere.

## Two-step reviewer onboarding

The current public reviewer registry gives `/root/phase1_code_review` only the
`independent_commit_reviewer` role. Phase 29 also needs the separately scoped
`independent_parity_reviewer` role to sign feature, UX-gate, and Reviewed-N/A
attestations.

This change adds that public role and updates the baseline's current-registry
digest. It deliberately leaves the external genesis approval digest unchanged.
Under the parent-pinned two-step policy, the new role cannot approve this
candidate; it becomes eligible only for a later candidate whose immediate
parent contains this registry version. The onboarding commit itself still
requires approval through the reviewer's pre-existing commit-review role.

## Remaining evidence work

- classify all 94 stable features against current production code and tests;
- retain Missing or partial states wherever acceptance is not fully met;
- build an exact-HEAD release manifest and byte-bound app artifact;
- run automated feature, security, performance, and workflow evidence;
- execute the supported-macOS manual UX checklist;
- independently sign evidence and the five Reviewed-N/A command rules;
- require all P0 features, G1–G10, zero blocker/critical defects, and at least
  90 percent weighted parity before declaring a release pass.

## Boundaries

No README is created. The ignored Notepad++ source tree is not staged or
committed. Open document tabs remain unlimited; the 100-entry bound applies to
recently closed/history state. This onboarding change implements no macro
feature and makes no release-parity claim.
