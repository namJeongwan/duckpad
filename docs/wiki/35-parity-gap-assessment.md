# Phase 29B — Parity gap assessment and shortcut contribution closure

Status: **Implementation assessment in progress; signed release evidence pending**

## Outcome

The frozen 94-feature baseline still reports zero because it intentionally
contains no candidate-bound evidence. That number is not the current product
implementation level. A conservative source-and-test assessment at
`804a1c4` plus this slice identifies 44 Full candidates, 23 partial candidates,
and 27 Missing candidates. Applying the frozen category formula produces a
provisional implementation-only score of **62.563 / 100**.

This is not an official parity score. The baseline states remain unchanged
until the exact app artifact, automated result, manual supported-macOS
checklist, and independent Ed25519 attestations all exist. Any item that fails
its full acceptance during that process must be downgraded.

## Exhaustive provisional classification

Every one of the 94 frozen IDs appears exactly once below. `Full` here means
the current production surface and existing tests appear to cover the frozen
feature bundle; it does not bypass the signed evidence requirement.

| Category | Candidate state by feature suffix |
| --- | --- |
| C1 | Full: F01, F02, F03, F04, F05, F06<br>Partial-0.50: F08<br>Missing: F07, F09, F10 |
| C2 | Full: F01, F02, F03, F05, F07, F10, F11, F12<br>Partial-0.50: F04<br>Partial-0.25: F08<br>Missing: F06, F09, F13 |
| C3 | Full: F01, F05, F13<br>Partial-0.75: F02, F03<br>Partial-0.50: F04, F06, F07<br>Partial-0.25: F12<br>Missing: F08, F09, F10, F11 |
| C4 | Full: F01, F02, F04, F06, F08<br>Partial-0.75: F03, F09<br>Partial-0.50: F05<br>Missing: F07, F10 |
| C5 | Full: F01, F02, F03, F06, F10<br>Partial-0.75: F04, F05<br>Partial-0.50: F09<br>Missing: F07, F08 |
| C6 | Full: F01, F04, F06, F08<br>Partial-0.75: F03, F05<br>Partial-0.25: F07<br>Missing: F02 |
| C7 | Full: F01, F02, F05<br>Partial-0.50: F08<br>Missing: F03, F04, F06, F07 |
| C8 | Full: F01, F02, F03, F04, F07, F08, F10<br>Partial-0.75: F06, F09<br>Partial-0.50: F05<br>Missing: F11 |
| C9 | Full: F01<br>Missing: F02, F03, F04, F05 |
| C10 | Full: F02, F05<br>Partial-0.50: F01<br>Missing: F03, F04, F06 |

The corresponding weighted category candidates are C1 10.400, C2 9.423,
C3 6.731, C4 9.800, C5 8.400, C6 5.750, C7 3.063, C8 7.364, C9 0.800,
and C10 0.833. Three P0 bundles remain partial: C2.F04 monitoring/read-only
indicators, C4.F03 complete advanced-search semantics, and C10.F01 the complete
editor/tab/session/recovery settings family.

## Extension keyboard contribution closure

Extension keybindings were previously parsed and signature-bound in the
manifest but discarded when native menu items were built. Enabled, authorized
extension commands now expose their declared keybindings through the native
Extensions menu and therefore through ordinary AppKit shortcut dispatch and
the unified command palette.

The native menu remains the final authority:

- declarations use a strict, deterministic macOS grammar;
- Command, Control, or Option is mandatory, so an extension cannot steal plain
  editor typing;
- duplicate modifier tokens, multiple key tokens, unsupported keys, and
  non-canonical package declarations fail closed;
- core application shortcuts always win, and extension-to-extension conflicts
  are resolved deterministically by the already stable command order;
- a rejected declaration leaves the command usable from the menu and palette,
  with a tooltip and accessibility value explaining why no shortcut is active.

The shipped sample currently declares `Command-Option-S`, which collides with
Save All. It is therefore deliberately shown without that shortcut instead of
shadowing a core file-safety command. Signed third-party fixtures prove that a
free declaration such as `Command-Option-K` is installed exactly.

The same slice closes the previously documented Extended-search escape gap.
Binary, octal, decimal, hexadecimal, and UTF-16 fixed-width escapes now follow
the pinned Notepad++ behavior, including literal fallback for malformed
numeric sequences and strict rejection of unpaired surrogate output. C4.F03
remains conservatively Partial-0.75 until the rest of its advanced regex and
manual UX acceptance is signed.

## Remaining implementation order

1. Finish the three partial P0 bundles before any release claim.
2. Close high-weight scratchpad gaps: named sessions, file rename/trash/print,
   line transforms, marks, change history, folder replace, and legacy encoding.
3. Keep Workspace browser/project roots hidden by product decision and keep
   C9.F02 macros Missing; recover the score through other implemented features.
4. Build the exact candidate artifact, run G1–G10 on supported macOS targets,
   sign automated/manual evidence and the five Reviewed-N/A rules, then update
   the frozen baseline only if the real score reaches its gate.

## Boundaries

No README is created. The ignored Notepad++ checkout is not modified, staged,
or committed. The user's existing foundation-document and Scintilla-vendor
script changes remain outside this slice.
