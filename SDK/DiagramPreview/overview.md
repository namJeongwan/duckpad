# Diagram preview components

D2 and Mermaid are independently installed native plugins. Each compiles these
Swift sources and `SDK/DuckpadNative/Swift/DuckpadHost.swift` into its own module;
the host does not link either plugin's UI or Mermaid runtime. The C ABI remains
`duckpad-native-1`. This is shared source for these two plugins, not a new stable
binary API. Build against the matching Duckpad checkout.

`DiagramPlugin` owns dock lifecycle, document/file reads, runtime settings where
needed, cached PNG/SVG export and the separate preview window. `DiagramRendering`
is the renderer boundary. D2 uses the authenticated helper's `renderD2` endpoint;
Mermaid embeds the existing pinned Mermaid 12.0.0 runtime into its signed native
module. `DiagramWebRenderer` turns SVG into a bounded PNG in nonpersistent WebKit.
It passes source as JavaScript arguments, blocks network/document scripts with
CSP, removes executable SVG elements/event attributes and drops external links.
Closing a preview cancels its work and fences late results. Source is never
written into plugin settings or sent to a remote rendering service.

The dock/window/canvas/settings/localization and native-entry conventions were
adapted from [Duckpad PlantUML](https://github.com/namJeongwan/duckpad-plugin-plantuml).
PlantUML keeps its existing separately distributed implementation. The D2 and
Mermaid lexers are Duckpad-owned structural lexers in the main editor, independent
of installation. Renderer validation is separate from syntax highlighting.

## Verification

With both plugin checkouts next to Duckpad and the existing Markdown dependencies
installed (`npm ci --prefix scripts/markdown-preview --ignore-scripts`):

```sh
# From the Duckpad checkout; accepts explicit standalone checkout paths.
bash SDK/DiagramPreview/test.sh ../duckpad-plugin-d2 ../duckpad-plugin-mermaid
```

The script builds both native modules, checks the host ABI prefix/UTF-8/bounds,
loads the real modules through their exported C ABI, and runs isolated AppKit
controller and WebKit rendering processes. Controller tests cover eight locales
at 300/560-point widths, settings visibility, stale exports/replies, Ctrl+W with
Korean input and unchanged document text. Rendering checks actual PNG pixels,
SVG sanitization, Mermaid flowchart/sequence/class diagrams, syntax failures and
cancellation. Test windows and temporary settings are separate from user state.

Host regressions:

```sh
DUCKPAD_D2_TEST_EXECUTABLE=/absolute/path/to/d2 \
  swift test --filter 'D2RuntimeTests|DiagramHighlightingTests|DiagramLanguageDetectionTests|SearchResultViewportTests'
# Also exercise the pinned download/checksum/cache path (requires network):
DUCKPAD_D2_TEST_SETUP=1 swift test --filter D2RuntimeTests
```

Check signed plugin artifacts with the production package loader, without
installing or enabling them:

```sh
DUCKPAD_D2_PACKAGE=/path/to/com.duckpad.d2.duckpad-plugin \
DUCKPAD_MERMAID_PACKAGE=/path/to/com.duckpad.mermaid.duckpad-plugin \
  swift test --filter nativeDiagramPackagesPassHostSignatureInventoryAndCompatibility
```

For an actual sandboxed XPC/render check, first build a development app and both
plugins, then pass absolute app/executable paths:

```sh
bash SDK/DiagramPreview/test-packaged.sh /absolute/path/Duckpad.app \
  /absolute/path/d2 /path/to/duckpad-plugin-d2 /path/to/duckpad-plugin-mermaid
```

This clones a disposable app, compiles a test entry point using the actual plugin
connection/render components, and signs only the clone with the host's existing
sandbox entitlements. The candidate app and its signed helper stay unchanged.
It checks authenticated D2 helper replies, D2-to-WebKit PNG/SVG and sandboxed
embedded Mermaid. It does not exercise installing/enabling through Plugins Admin.

## Local validation, November 11, 2026

- 20 focused host tests passed: D2 input/process/setup/cache checks, actual D2
  rendering, positive-control external-file import denial, syntax/detection,
  existing PlantUML highlighting and 10 search viewport regressions.
- Nine native package/activation/installation tests passed. Both final signed
  universal plugin packages passed the production loader and native C ABI smoke.
- AppKit controller and WebKit renderer checks described above passed. All eight
  locale files have identical key sets and parse successfully; translated control
  bounds were checked in actual test windows at both widths.
- The native arm64 development app passed `verify_macos_app.sh` and the default
  `smoke_macos_app.sh`. Optional save-panel automation was skipped. The packaged
  D2 XPC/error-reply and Mermaid rendering checks passed separately.
- Both plugin modules cross-compiled for arm64 and x86_64. Intel hardware execution
  was not tested. The app uses ad-hoc signing and was not notarized or published.
- Broader search checks also reproduce two existing presentation-test failures
  on the unchanged baseline: `incrementalFindDoesNotExpandTheResultsList` and
  `routedFolderSearchOpensIdentityCheckedResultAndSelectsUTF8Range`. Their table
  population assertions are separate from the 10 passing native viewport tests.
