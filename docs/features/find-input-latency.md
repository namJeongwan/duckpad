# Find input latency

A live sample of the installed Duckpad 0.14.3 (65), taken while the user typed
English and Korean in Ctrl+F, identified this synchronous main-thread path:

```
SearchFieldEditor.setMarkedText
  -> SearchPanelView.controlTextDidChange
  -> DuckpadWindowController.cancelSearch
  -> ScintillaEditorAdapter.clearSearchHighlights
  -> every cached DPScintillaEditorView.clearSearchHighlights
  -> refreshSearchOverview
  -> SCI_POINTYFROMPOSITION
  -> LayoutLine
```

Clearing Find highlights always recomputed the fallback word-occurrence ticks,
even in cached documents with no active Find highlights. Wrapped long lines
in other tabs therefore slowed input in a tiny current document. Korean
composition triggered the same work for each marked-text update; keeping live
composition notifications is necessary for the existing Korean search behavior.
The root problem is unrelated work performed synchronously in that callback.

## Change

- Native clearing returns immediately when every shared pane has no active Find
  highlights. Existing word ticks remain intact. Actual Find highlights still
  clear, including shared panes, empty queries and edits.
- Incremental Find displays the count without constructing or retaining up to
  100,000 hidden result rows. Explicit Find All still displays results.
- Typing and incremental count updates do not request dialog resizing unless
  result visibility changes. Same-size resize requests skip forced layout.
- Search range validation uses one continuation-byte lookup per edge in
  already validated UTF-8 text. Binary documents remain rejected; the general
  native character-boundary helper is unchanged.

## Reproduction and evidence

The regression opens a tiny active document, then leaves three cached 8 MB
wrapped documents, each with 100,000 published word-occurrence markers.
Seven real SearchFieldEditor marked-text transitions include `사용중` → `사용`
and `유후` → `유ㅎ` → `유휴`. Existing word markers must survive the input.

With only the inactive-clear guard removed, the test fails its 50 ms input
budget at **1,035.54 ms maximum**, with every marker precondition satisfied.
The live stack and this controlled failure identify the same cause.
Results and final packaged checks are recorded in
[find-input-latency-validation.json](find-input-latency-validation.json).

The live sample contains call stacks, not document contents. Original user
files were not edited. The sampling tools initially captured idle time, so
those samples are not used as evidence of an input bottleneck. Isolated input
in a tiny workspace was only about 2–10 ms; the inactive-document fixture was
needed to reproduce the actual user condition.

The fixed regression passes with a **9.57 ms maximum**, preserving all existing
word ticks and the final composed query. The 50 ms input goal passes for this
reproduced condition (about108× improvement). Twelve Find-panel test functions
and the native search/log functional runs pass. This is not a universal
performance claim: publishing100,000 highlights in an8MB wrapped document
still measures51.82 ms. Hidden-row presentation drops from39.66 to0.09 ms, and
the next input in that stress fixture measures6.45 ms. That publication gate
remains explicitly failed in the validation JSON.

The combined native preview is `build/tail-phase3-find-preview/Duckpad.app`,
version0.14.3 (65), ad-hoc signed and not notarized. It includes phase-3 common
log and ANSI styling. Bundle verification, serial general app smokes and the
packaged Log/RGB/Plain Text smoke pass. Native save-panel automation is skipped.
The final standard run executes31 panel/search/log/detection test functions;
four opt-in stress functions are skipped there. The controlled small-file input
regression runs separately and passes. Independent source/evidence review finds
no remaining Blocker/Major; the documented stress failures remain open.
