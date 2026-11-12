# Mermaid preview

The optional [`com.duckpad.mermaid` native plugin](https://github.com/namJeongwan/duckpad-plugin-mermaid)
is distributed separately from Duckpad. Version **0.1.0** requires host API
**1.4.0** or later within API 1.x and macOS 13+. It uses native C ABI v1.

Install **Mermaid** from **Plugins Admin → Available Plugins**, or download the
[0.1.0 release ZIP](https://github.com/namJeongwan/duckpad-plugin-mermaid/releases/tag/v0.1.0),
extract it and select the `.duckpad-plugin` folder with **Install Plugin**.

Open a `.mmd` or `.mermaid` document and run **Plugins → Mermaid**. **Preview**
reads the current editor buffer, including unsaved edits; **Open file…** opens a
chosen UTF-8 file. Fit-width, zoom, scrollbars, a larger separate window and
PNG/SVG export follow the PlantUML/D2 preview controls. **Ctrl+W** closes the dock.
Rendering is explicit. Supply Mermaid source directly, without Markdown fences.

The plugin embeds the same pinned **Mermaid 12.0.0** runtime used by Duckpad's
Markdown preview. No Node.js, Chromium download, CLI server, remote rendering
service or runtime setup is needed when using the installed plugin. Node.js and
npm are needed only to build it. Runtime bytes are compiled into the signed
native module; the native loader's resource policy is unchanged. Upstream license
notices are included in the package.

Rendering uses a nonpersistent WebKit page, strict Mermaid configuration,
network-blocking CSP and SVG cleanup. Document scripts, event handlers and
external links/resources are removed or blocked. Click actions and remote
images are unsupported. This does not sandbox arbitrary native plugin code;
installing a native plugin authorizes trusted code in the host process.

Flowcharts, sequence and class diagrams have actual rendering/pixel coverage;
other Mermaid 12 diagram families use the same engine but were not individually
verified. Source is limited to 512 KiB and 5000 edges, each render to 30 seconds,
and output to 32 MiB. PNG snapshots are bounded to 8192 pixels per axis and
16 million pixels; extreme aspect ratios report an error. Light/dark appearance
is selected when rendering. Source is not retained in plugin settings. Closing
cancels the render and fences late callbacks. All eight UI languages are included.

## Build and test

Install the matching host's existing pinned Markdown dependencies first:

```sh
npm ci --prefix /path/to/duckpad/scripts/markdown-preview --ignore-scripts
# From the standalone plugin checkout:
bash scripts/build.sh native /path/to/duckpad
# Compile both architectures for a distribution candidate:
bash scripts/build.sh universal /path/to/duckpad
# Requires the already-configured publisher key outside the repository:
swift scripts/sign.swift dist/com.duckpad.mermaid.duckpad-plugin
swift scripts/verify.swift dist/com.duckpad.mermaid.duckpad-plugin
```

Install the signed directory through **Plugins Admin → Install Plugin**. Distribution and local builds use ad-hoc Mach-O signing and publisher package
signatures, without Apple notarization. See [shared preview verification](../../SDK/DiagramPreview/overview.md).

## Editor and Markdown support

The development main editor recognizes `.mmd`/`.mermaid`, offers Mermaid in the
Language menu, and highlights headings, arrows, comments, strings, numbers and
common properties using its own palette. This structural lexer does not validate
syntax or add folding. It is independent of the plugin. Existing Mermaid fenced
blocks in Markdown preview remain a built-in feature.

Upstream: [Mermaid usage](https://mermaid.js.org/config/usage.html).
