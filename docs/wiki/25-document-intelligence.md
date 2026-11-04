# Current-document completion, language servers, and symbol outline

Status: **Released in Duckpad 0.17.0; optional language packages are version 0.1.0**

## User contract

The native editor opens completion automatically from the first committed word
character or a supported member-access operator. Local candidates refresh on the next task
turn without a typing-pause timer. Backspace, forward Delete, selected-text deletion
and cut also refresh the list. Deleting the last prefix character, typing whitespace or moving to an empty
line closes the list. Explicit manual completion can list candidates at an empty
caret.
Only semantic server requests use a 60 ms quiet interval. `Control-Space` also
requests completion. An empty local match clears the previous panel immediately,
even while a slow server request is outstanding. The panel has
symbol icons, highlighted matching characters, secondary type information,
and documentation when supplied by a language server. Up/Down selects, Return
inserts, Tab also replaces the remaining word suffix, and Escape closes the panel.

String and comment contexts suppress code completion before a document snapshot
or language-server request. This also closes an existing panel when typing enters
a string and prevents deletion inside a string from reopening it. Single/double
quotes, unfinished strings, multiline/raw strings, characters, regexes and Ruby
heredocs use Lexilla's semantic style metadata rather than counting delimiters.
Python and Ruby interpolation expressions retain completion where the lexer marks
their embedded code. Untyped scratch text uses a bounded escaped-quote check on
the current line and preserves apostrophes in ordinary words such as `don't`.
When styling is pending or cannot be refreshed within the 256 KiB synchronous
budget, completion remains quiet. The untyped line check has a 4 KiB budget.

Current-document words and bundled language keywords work without installing a
server, including in untitled documents. CodeMirror's existing fuzzy matcher ranks
prefixes, camel-case boundaries and abbreviations; matching also folds diacritics.
The current word is omitted and results are deduplicated and capped at 200.
Document tokens are indexed once, then updated around accepted edits rather than
rescanning the entire buffer after every keystroke.

Saved Python, Ruby/Rails, and Rust documents additionally request semantic
completion through installed, enabled language plugins for basedpyright (Python default), Pyright, ty, Ruby LSP, and rust-analyzer. Semantic results precede
local fallback candidates and retain the server's sort order. Member access uses
semantic candidates rather than unrelated document words. Documentation and
additional import edits are resolved lazily. The primary insertion and additional
edits form one editor transaction and one undo group.

`Command-Option-O` continues to open the searchable current-document symbol
outline. Return or double-click reveals the exact UTF-8 name range. The outline
is a bounded syntax heuristic, separate from language-server completion.

## Server setup

First install the desired language support plugin from Extensions.
Servers are external tools, not bundled with Duckpad. For Python, install the
selected server (`uv tool install basedpyright`, `uv tool install ty`, or
`npm install -g pyright`). Ruby uses `ruby-lsp`; Rust uses the `rust-analyzer`
component for your Rust toolchain. Projects need their normal dependencies and toolchain installed.
Ruby projects with a Gemfile must have a valid Gemfile.lock (`bundle install`).
Ruby LSP owns its composed bundle and Rails add-on discovery; Duckpad does not
install gems or language servers itself. Ruby LSP can install its own composed
bundle dependencies on startup, as it does in other clients.

Project roots are detected from Python configuration files, Gemfile, Cargo.toml,
rust-project.json, or `.git`, searching up to 64 ancestors. The launch environment
searches the project's `.venv/bin`,
`~/Library/Application Support/Duckpad/LanguageServers/bin`, mise/rbenv/asdf
shims, `~/.local/bin`,
`~/.cargo/bin`, Homebrew, and system executable locations. It does not evaluate a
login shell or accept arbitrary server commands. An unavailable server falls back
to local completion. A cold Ruby bundle/index or Rust workspace load may need
another completion request before semantic results are available.

## Architecture and ownership

Application owns the capture, prefix, word index, matching/provider contracts,
debouncing and stale-result checks. Infrastructure provides CodeMirror matching
through JavaScriptCore and typed LSP through ChimeHQ LanguageClient,
LanguageServerProtocol, and JSONRPC. A small, licensed subset of LanguageClient is
vendored to avoid bringing in unused file-watching dependencies. Matching uses
the pinned CodeMirror autocomplete implementation; `scripts/markdown-preview/
build-completion-matcher.mjs` regenerates its bundled JavaScript.

The CodeEditSourceEditor CodeSuggestion UI is adapted into a separate AppKit
module. It retains inset row selection and separates labels, details, icons, and
preview information. Scintilla remains the editing engine. The adapter owns the
non-activating completion panel, UTF-8 edits, focus checks, and undo integration.
Upstream revisions, licenses and adaptation details are recorded in each vendor
or generated-resource directory and included in packaged third-party licenses.

The sandboxed app launches a server through a dedicated connection to the existing
authenticated, unsandboxed terminal helper. JSON-RPC travels over separate pipes,
not terminal emulation. The connection owns its process lifetime. The helper
re-verifies the signed plugin launch definition and determines the authoritative
project root; the app reuses sessions by workspace, folder, language and root. At most four sessions and
32 synchronized documents per session are retained. Closing a buffer sends
`didClose`; adapter teardown stops all server processes.

## Optional language plugin interface (host API 1.5)

Language-specific policy is supplied by independently installable, signed
`language-provider` packages. The built-in server catalog, Python-specific
adapter, interpreter resolver and Python preferences page have been removed.
The host retains the common LSP client, generic interpreter discovery, JSON
configuration-template renderer and language settings UI.

See the [language plugin SDK](../../SDK/LanguageSupport/language-support.md) and reference
[Python](../../LanguagePlugins/com.duckpad.python.duckpad-plugin/plugin.json),
[Ruby/Rails](../../LanguagePlugins/com.duckpad.ruby.duckpad-plugin/plugin.json),
and [Rust](../../LanguagePlugins/com.duckpad.rust.duckpad-plugin/plugin.json)
packages. They are not app-bundled and are not registered by default. Normal
Extensions installation enables them; discovery alone is not authorization.
Python supplies basedpyright (default), Pyright and ty; Ruby/Rails supplies
Ruby LSP; Rust supplies rust-analyzer. The referenced SDK schema declares server
commands, project markers, interpreter paths, initialization/configuration
settings and installation guidance without LSP implementation types in Domain.

The `language.servers` and `documents.read` application grants are bound to the
package identity/digest. `ExtensionWorkspaceUseCase` publishes authorized
`LanguageServerRegistration` values on activation changes. The helper verifies
their original signed inventory and exact definition before resolving project
roots or launching. No raw command or environment rule outside that signed
inventory can override the chosen provider. The common client rechecks persisted
authority before requests and before returning semantic results; another window
cannot keep using authority withdrawn by a plugin disable/revoke. Policy-generation
changes also refresh other windows. Ambiguous language owners are quarantined.

Preferences → Language Support offers All defaults, Current workspace, and
Selected folder. It initially selects the current workspace. Registered folder
choices use their durable root IDs; standalone projects use a path key within
the owning workspace. `SessionID` provides the persisted workspace namespace,
so two windows opening the same folder can choose different servers/interpreters
and recover those selections after relaunch.

Interpreter priority is explicit folder, explicit workspace, automatic plugin
project paths, global default, then executable-name discovery. Server priority
is folder, workspace, global, then plugin default. The legacy development `python`
archive migrates to the generic map; old project-path choices are copied into
independent workspace snapshots. Clearing a folder override persists an empty
entry and restores inheritance without reimporting a legacy choice.

Each helper launch packet contains only its owner's settings. Root and session
keys include workspace/folder identity. Providers compare only their own settings
projection: changing workspace B preserves A's connection, pending work and
completion panel. The settings UI also preserves A's text-field draft when B
changes. Root lookups are performed by the authenticated helper, cached up to
256 entries, and invalidated with relevant configuration. Nested projects keep
separate sessions. Disabled/uninstalled plugins withdraw registrations, stop
connections, clear candidates and fence pending launches/results. Project
environments, files and stored preferences are retained. Syntax support and
local word/keyword completion remain available without an LSP plugin.

Server binaries remain external, separately installed tools. Installation commands
are displayed as guidance; automatic server downloads are not implemented.
The signed language packages are published through the official plugin catalog. No new native C callbacks, WASM imports or generic process API were
introduced. LSP processes still run through the existing unsandboxed helper;
its server grant is not a filesystem sandbox. Broader LSP editor features beyond
completion/resolve remain separate work.

## Declaration context and Duckpad completion appearance

Automatic completion treats a dot with a receiver as member access; a single
colon is never a member operator. `::` remains a namespace operator for supported
languages such as Rust, Ruby and C++. Bare dots, Python slices, numeric decimal
dots and block/type/dictionary colons do not request a zero-prefix candidate list.
A bounded lexical check suppresses local words after declaration heads. New type
names (`class`, `struct`, and related forms) suppress automatic requests; function
name slots (`def`, `fn`, `function`) use semantic candidates only. Python `async def`, Ruby
receiver-qualified methods and Rust visibility/function modifiers are covered.
References inside base-class lists or type annotations still complete. This is a
local trigger heuristic over at most 2,048 bytes of the current line, not a full
language parser; manual completion remains explicit.

The completion panel now uses the shared `EditorThemeColors` panel, border,
selection, foreground and muted roles. Small monochrome symbols and code text
capped at 13 pt replace the large colored badges and editor-zoom-dependent rows.
Repeated source labels and the visible keyboard-help footer are omitted; keyboard
help remains accessible. The list uses compact complete rows, adapts to available
space above/below the caret, and stays inside its parent content frame as well as
the visible screen. Documentation remains separately scrollable, capped at 160 pt.

## Special methods and inherited overrides

Function-name slots now query the active language server instead of suppressing
all completion. Document words and language keywords remain excluded there.
Candidates are restricted to the typed method-name prefix. In a Python class,
basedpyright and Pyright return `__init__`, `__repr__`, and other methods after
`def __`; inherited ordinary methods also appear after their matching prefix.
This uses server results, not a hard-coded host list. New class/type names and
empty automatic prefixes retain their existing suppression. Top-level `def __`
does not receive class methods from these tested servers.

Server method stubs contain continuation lines relative to the insertion line.
`adjustIndentation` travels with a suggestion through matching and resolution;
the editor adds the insertion line's leading whitespace and retains its line
ending before applying the existing atomic completion batch. Additional import
edits keep their original ranges. Expanded text is bounded to 64 KiB. Native
checks cover spaces, tabs, nested classes, CRLF, mixed line endings, caret
position and one-step Undo. Both live Python servers are also exercised through
the native editor and actual signed plugin definition.

The standalone probes received 23 class-method candidates from both locally
installed basedpyright and Pyright with snippet support disabled. The tested ty
server returned no candidates in this slot; the host does not substitute another
server or fabricate a fallback list. The packaged regression posts a real Tab
event, verifies the generated method body and caret, checks Undo/Redo, then
reopens the method list for inspection.

## Bounds and editing safety

Local completion and outline reject documents above 4 MiB before copying text.
Semantic completion has a 1 MiB document limit. Tokens are capped at 256 UTF-8
bytes. Initial tokenization runs off the UI actor and checks cancellation;
ordinary edits rescan a bounded neighbourhood, while large replacements invalidate
the cached index. IME marked text, selected text, multiple carets, read-only and
binary buffers do not request automatic completion. The CodeMirror Markdown
surface is outside this native completion path.

Every capture identifies the buffer, revision, exact split pane, language and
caret. Publication, documentation updates, and acceptance revalidate that state.
Escape, tab/focus changes, and teardown invalidate pending work. Resolved
additional edits are bounds/overlap checked and applied through the existing
workspace batch reservation. Stale results cannot mutate a newer document.
LSP positions convert between UTF-16 and Scintilla UTF-8, including Korean,
surrogate pairs, and CR/LF/CRLF. Startup, requests, and resolution have timeouts;
transport failures back off before retrying. Server stderr is drained without
logging document contents.

Clients advertise plain-text insertion rather than snippets. Completion snippets,
server commands, workspace edit requests, diagnostics, signature help, references,
and semantic outline are not implemented in this slice. Completion documentation
is displayed as bounded text. Rails-specific behavior depends on Ruby LSP and the
project's Rails add-on; a full Rails application has not been exercised here.

## Validation

- Application tests cover bounded completion/outline analysis and stale captures.
- Native editor regressions exercise committed typing, Korean IME, selection and
  split-pane guards, read-only buffers, Escape, Tab/Return, and Undo.
- Rich completion integration uses real Scintilla, CodeMirror matching and the
  CodeEdit panel, including suffix replacement, atomic additional imports, and
  stale acceptance.
- Infrastructure tests cover fuzzy/Unicode matches, incremental token counts,
  UTF-16 coordinate conversion, restricted launch presets, and project roots.
- A real pipe-protocol fixture verifies initialization capabilities, document
  synchronization, server-to-client configuration replies, and lazy resolution.
- Optional tests use installed Pyright, Ruby LSP, and rust-analyzer to request
  actual semantic members/functions. Set `DUCKPAD_PYRIGHT_TEST_EXECUTABLE`,
  `DUCKPAD_RUBY_LSP_TEST_EXECUTABLE`, and
  `DUCKPAD_RUST_ANALYZER_TEST_EXECUTABLE` to enable them. Ruby's optional test locks
  a temporary project using locally installed gems.
- UI resources include all eight supported locales. Key parity can be checked
  automatically; actual visual verification is limited to the current macOS
  appearance and locale.

Validated on Apple Silicon/macOS 27 with native Scintilla integration, real
basedpyright, Pyright, ty, Ruby LSP and rust-analyzer, plus packaged helper-backed
completion. Two real windows opening the same file retain independent interpreter
choices, selectively restart connections and recover their workspace IDs/settings
after relaunch. Packaged checks cover signed installation and opt-in activation,
plugin withdrawal, first-character input, deletion to an empty prefix, quoted
input, class declarations, member access and method-stub Tab/Undo/Redo.

The universal 0.17.0 (70) release passes bundle, resources, XPC isolation and
ad-hoc signature verification, 164 focused Release tests, isolated application and
Markdown smoke, all eight packaged locale-loading checks and final helper-backed
completion/method-stub/reload checks. English/Korean Language Support preferences
and dark/light completion panels were visually inspected during development.
All eight locale files parse and share 1,285 keys. Native Save-panel automation,
the other six locale preference windows, Intel hardware execution, macOS 13
runtime, a full Rails project and the full test suite remain unverified.

Language packages are version 0.1.0 with host API minimum 1.5.0 and are listed in
the official catalog. Their independent repositories are
[Python](https://github.com/namJeongwan/duckpad-plugin-python),
[Ruby/Rails](https://github.com/namJeongwan/duckpad-plugin-ruby) and
[Rust](https://github.com/namJeongwan/duckpad-plugin-rust). See the
[release validation record](../releases/0.17.0-validation.json) for artifact
digests, source identity, checks and limitations.
