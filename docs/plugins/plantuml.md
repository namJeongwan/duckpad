# PlantUML

The native PlantUML plugin has its own repository,
[duckpad-plugin-plantuml](https://github.com/namJeongwan/duckpad-plugin-plantuml).
It requires Duckpad **0.10.0** and host API **1.4.0**. Existing Duckpad releases with API 1.3.0 cannot load it. Open the
plugin through Plugins → PlantUML or **Command-Option-U**, then choose Preview
or the Open file folder icon. The preview supports zoom, both scroll directions, a
separate large window, and PNG/SVG export. Close or **Control-W** closes the dock;
the editor document stays open. Command-W retains the host's normal routing.

The compact dock places **PlantUML · Settings · Close** in its header, document
and export actions in one row, and status beside zoom controls. Icon buttons
have localized tooltips and accessibility labels. Hover a shortened status
to read its full text.

Java and PlantUML paths live in **Settings → Runtime settings**, independently of the
preview. Paths persist in the plugin's own `PluginData` directory; source text
is not persisted there. Automatic setup downloads a private Eclipse Temurin
Java 21 JRE and PlantUML LGPL 1.2026.8, verifies their SHA-256 digests, and reuses
the downloaded files. It does not change system Java or shell settings.

For offline use, enter a Java 11+ home, `.jdk`/`.jre` directory, or its `bin/java`
executable, plus an official **1.2026.8 LGPL or GPL JAR**. Other JAR versions
are rejected by checksum verification. A local copy of the managed runtime
also works without network access. The tested sequence diagrams need no
Graphviz installation; other diagram types that require external Graphviz
are outside this first version.

Duckpad remains sandboxed. Its existing authenticated native installer helper
performs setup and rendering as the logged-in user without administrator
privileges. Each Java render additionally runs with network access denied,
reads limited to system/runtime/JAR/job files and the OS entropy devices
(`/dev/random` and `/dev/urandom`), and writes limited to its job
folder. PlantUML's `SANDBOX` profile also disables external includes. Source is
never sent to a remote renderer. This is a native plugin, so its existing
`runtime.native` authorization is still a code-trust boundary rather than
fine-grained isolation for arbitrary plugin code.

OS entropy access avoids the JVM's slow fallback seed generation while keeping
private files and network access blocked. In a local Apple Silicon comparison,
the same large sequence rendered in about 1.5 seconds instead of 9.8 seconds.
Rendering reuses one sandboxed JVM for both PNG and SVG through PlantUML's
local pipe protocol. After ten minutes without a render it exits, and the next
request starts it again. Java/JAR path changes, cancellation, and rendering
errors discard the worker. The XPC helper stays alive while the worker exists;
no network service or additional renderer dependency is introduced. Timings
depend on the diagram and machine.

One complete `@startuml`…`@enduml` diagram up to 512 KiB is supported. Rendering
has a 90-second process limit, 512 MiB Java heap, and 32 MiB output limit.
Closing during setup/rendering cancels that connection's work. Syntax,
download, verification, missing-runtime and file errors appear in the dock.
Translations ship for all eight Duckpad languages.

Build and sign with the existing configured publisher key:

```sh
# Run in the standalone duckpad-plugin-plantuml checkout:
bash scripts/build.sh universal
swift scripts/sign.swift dist/com.duckpad.plantuml.duckpad-plugin
```

Install the signed directory using Plugins Admin in a matching host. Local
builds use ad-hoc Mach-O signing; they are not Developer ID signed or notarized.
Java and PlantUML are downloaded from their official publishers, not embedded
in the plugin package. Their upstream license files remain with the runtime.

Focused runtime verification accepts a local test folder containing
`input.puml`; fixtures and rendered images should stay outside tracked source:

```sh
# Run native ABI/UI tests in the standalone plugin checkout:
bash scripts/test-native.sh
# Run helper/runtime tests in the Duckpad checkout:
bash scripts/test_plantuml_process.sh
bash scripts/test_plantuml_runtime.sh /path/to/test /path/to/java /path/to/plantuml.jar
# Force the managed-runtime setup path instead of installed Java:
bash scripts/test_plantuml_runtime.sh /path/to/test unused unused --install
```

See [PlantUML requirements](https://plantuml.com/starting),
[PlantUML security](https://plantuml.com/security), and
[Temurin](https://adoptium.net/temurin/releases/).

## Editor syntax and color previews

PlantUML syntax highlighting belongs to the main editor and works without the
plugin. Files ending in `.puml`, `.plantuml`, `.pu`, or `.wsd` select PlantUML;
an otherwise unrecognized file beginning with a supported `@start` directive
also selects it. A recognized filename/extension or manual language choice
retains precedence. The Language menu also offers PlantUML. Commands,
directives, skin parameters, arrows, numbers, quoted text, and comments use the
editor palette, including both high-contrast palettes. This is structural
highlighting, not syntax validation or a complete PlantUML grammar.

Hexadecimal colors appear as small gutter chips without changing source or
syntax colors. Click a chip, choose a color, then click Apply to change the
literal in one undo action. Multiple colors on a line offer a choice menu.
Alpha is supported; PlantUML short colors with alpha expand to the valid
8-digit form. CSS/JSON and other styled documents share the gutter, while
comment tokens and Plain Text do not show chips. Read-only files keep chips
visible but disable editing. Color edits are also disabled while any pane sharing
the document has an active IME composition. Closing/changing a document, editing its contents,
or changing its language cancels an open chooser so an old selection cannot
change a different document.

Preview work is limited to visible lines: at most 512 display lines,
16 KiB per line, 256 KiB in total, and 256 literals per refresh. Colors beyond
these limits are omitted; the gutter does not scan an entire large file.

Plugin releases and their source live in the standalone repository. The
[duckpad-plugins catalog](https://github.com/namJeongwan/duckpad-plugins) records
the exact release URL, archive checksum and publisher key. Publish the plugin
asset before merging catalog metadata, then release the compatible host.
