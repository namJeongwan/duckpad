# Editor conventions and snippets

Duckpad provides these features in the app itself. No plugin is required.

## Project rules

Enable **Preferences → Indentation → Use .editorconfig rules** (on by default).
Rules are read asynchronously from the file's directory and its ancestors. The
nearest matching section wins; `root=true` stops traversal and `unset` removes
an inherited value. Rules refresh when switching files and before saving. Save
As uses the destination directory. Existing text is not reformatted on open.

Supported properties:

- `indent_style=space|tab`, `indent_size=1..16|tab`, `tab_width=1..16`.
  Indentation size and visual tab width can differ.
- `end_of_line=lf|crlf|cr`, applied when saving.
- `charset=utf-8|utf-8-bom|utf-16le|utf-16be`, used as an opening hint and save
  encoding. Automatic opening respects the file's BOM before the project hint;
  the hint is used only for BOM-less files. Explicit Open As / encoding conversion
  commands take precedence.
- `trim_trailing_whitespace=true|false` and `insert_final_newline=true|false`.
  An explicit false final-newline rule removes terminal line breaks; empty
  documents remain empty. Unsupported properties and values are ignored.

The reader supports `*`, `**`, `?`, character lists, brace alternatives, small
integer ranges and escaped wildcard characters. It bounds each configuration
file to 1 MiB, patterns to 4096 bytes, brace expansion to 256 steps and integer
ranges to 128 values. Pathological pattern matching is stopped after a short
execution budget. Latin-1, `max_line_length`, variables and custom properties
are not supported. This is not a claim of full EditorConfig conformance.
See the [EditorConfig specification](https://spec.editorconfig.org/).

Sandbox access matters: a file-only permission may not grant access to a sibling
`.editorconfig`. Use **File → Open…**, press **Cmd+Shift+G**, and enter the full
path to `.editorconfig` once, then switch back to the document. Duckpad retains
that file's authorized bookmark and restores it when reading rules after a
restart. Folder access already granted to Duckpad also works. Unreadable
configuration files are skipped, without displaying permission prompts during
typing. The `[*]` section includes extensionless names such as `new 51`.

## Indentation detection

**Preferences → Indentation → Detect indentation from document** is on by
default. Duckpad samples at most 64 KiB / 1000 lines and needs repeated evidence;
a single aligned line does not override the defaults. Detection does not rewrite
whitespace. The precedence is explicit project rules, detected indentation,
then the global override or language default. Disable detection to always use
the configured defaults when project rules are absent.

## Save cleanup

**Preferences → Formatting** provides trailing whitespace removal and final
newline insertion. Both default to off; project rules can explicitly override
them. Cleanup removes ASCII spaces/tabs at line ends, including blank lines.
Enabling it for Markdown also removes the two spaces used for hard line breaks.

Cleanup follows Format on Save, uses the normal undo/recovery transaction, and
retains the file conflict checks. Save also checks these rules on unmodified
documents. If neither the contents nor the requested format changes, the file
is left untouched. Scanning runs off the UI thread; applying many
edits still takes time on very large documents. A concurrent edit invalidates
the save instead of overwriting the newer text. With both options disabled and
no matching project rule, the cleanup does not materialize or scan the document.

## Snippets

Open **Edit → Snippets…**. Add a name and plain-text template, optionally restrict
it to a language, then save. Choose an existing snippet to edit, delete or insert
it. Insertion replaces the current selection and is undoable. The editor must
be writable, with one selection and no active IME composition.

```text
for ${1:item} in ${2:items}:
    print($1)
$0
```

- `${1:item}` creates a field with default text; `$1` repeats the same field.
- Tab advances in numeric order, Shift+Tab moves back, and `$0` is the final caret.
- Repeated fields are selected together for native multi-selection typing.
- Esc ends navigation. Editing outside a field, switching documents/groups or
  using a modified keyboard shortcut also ends the session.
- `\$`, `\}` and `\\` insert literal characters. Nested placeholders, choices,
  variable expansion, transformations and executable scripts are not supported.
- Multiline insertion follows the editor's EOL mode and adds the current line's
  leading indentation. The template's own internal indentation is preserved.

Snippets live in the normal settings archive and survive restart. Limits are
200 snippets, 256 UTF-8 bytes per name, 64 KiB per template, and 768 KiB for the
encoded snippet collection. Expansion is limited to 256 fields and 1 MiB. Conflicting saves from an older snippet panel are
rejected; close and reopen the panel to get the current collection.

## Validation

Focused unit and native Scintilla tests cover rule hierarchy, matching, bounded
indent detection, old settings compatibility, save/Save As, Unicode cleanup,
Undo/recovery, snippet positions, linked fields and read-only/IME admission.
The separate tab-width path is exercised through Python smart Return. Native
`keyDown` tests cover typing through repeated snippet fields; packaged UI checks
cover Korean panel layout, Save persistence and Tab/Shift+Tab navigation. The
macOS screen locked during the remaining interactive typing check, so that
physical-keyboard verification remains outstanding. Other locale layouts have
not been visually checked.

The final native app bundle passed resource, XPC isolation configuration and
signature verification. A final packaged GUI save smoke timed out while the
screen was locked and left its isolated fixture unchanged; that packaged save
check remains unverified. Native integration tests cover the save behavior.

The subsequent sandbox-access fix was verified in a new native package: open
an external `.editorconfig` through LaunchServices, exit the app, reopen an
extensionless `new 51` fixture in a new process, focus its editor and deliver a
Tab key event. Saving produced exactly two ASCII spaces. This verifies retained
configuration access after restart and native Tab input in the sandbox without
changing any user document. The related 16 configuration/integration tests and
app bundle verification also passed.

The review fixes passed 58 tests across five suites, including BOM precedence,
explicit encoding overrides, malformed-BOM read-only fallback, cleanup on clean
documents, Undo/recovery, external conflicts and unchanged-file preservation.
The new native package passed bundle verification. Three isolated sandbox
fixtures confirmed BOM conversion with cleanup, cleanup without an edit and
an unchanged save retaining its inode. Each reached the smoke hook's successful
save path, but its `NSApplication.terminate` call timed out; only those isolated
test processes were stopped. Automatic smoke termination remains unverified.
