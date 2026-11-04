# Language support plugins — host API 1.5

Language support is optional. Duckpad owns the LSP client, popup, UTF-8/UTF-16
conversion, document synchronization, completion edits and Undo. An installed,
enabled language plugin owns server choices, root markers, environment discovery,
initialization/configuration templates and installation guidance. No language
plugin or server executable is bundled into the app by this implementation.

The reference packages are [Python](../../LanguagePlugins/com.duckpad.python.duckpad-plugin/plugin.json),
[Ruby/Rails](../../LanguagePlugins/com.duckpad.ruby.duckpad-plugin/plugin.json), and
[Rust](../../LanguagePlugins/com.duckpad.rust.duckpad-plugin/plugin.json).
Their exact signed `.duckpad-plugin` directories can be selected with
**Extensions → Install Plugin…**. The normal installation path enables the plugin;
filesystem discovery alone never enables an imported package. The Python plugin
chooses basedpyright by default and also offers Pyright and ty. Ruby uses Ruby LSP;
Rust uses rust-analyzer. Server binaries remain separately installed tools.

## Manifest contract

Use the existing signed package inventory (`plugin.json`, `SHA256SUMS`,
`SIGNATURE.ed25519`) and these manifest fields:

```json
{
  "runtime": {
    "kind": "language-provider",
    "module": "plugin.json",
    "abi": "duckpad-language-1"
  },
  "capabilities": [
    { "id": "language.servers", "scope": "application" },
    { "id": "documents.read", "scope": "application" }
  ]
}
```

The API range must include host API 1.5.0 and declare a minimum of at least 1.5.0.
Declare the editor language ID in `contributes.languages`, then add its service to
`contributes.languageServices`. The [service schema](language-service.schema.json)
describes this contribution. The reference manifests include the full identity,
publisher, API range and empty command/keybinding/snippet/theme arrays required by
the package schema.

| Field | Purpose |
| --- | --- |
| `languageID`, `displayName` | Editor language ID and technical display name |
| `defaultServerID` | Default choice from this service's `servers` |
| `projectRootMarkers` | Relative files/directories searched upward, up to 64 ancestors |
| `projectExecutableDirectories` | Relative project locations for server executables |
| `interpreter` | Optional `projectPaths` and fallback `executableNames` |
| `servers[].id`, `command` | Stable choice ID and executable basename/argument array |
| `servers[].initializationOptions` | Optional JSON template passed to `initialize` |
| `servers[].configuration` | Optional JSON template returned by `workspace/configuration` |
| `servers[].installHint` | Command displayed as installation guidance |

The template values `${interpreter}` and `${projectRoot}` must occupy an entire
string value. They are substituted as LSP JSON data, never into an executable or
shell string. A missing interpreter omits that value. Configuration requests for
`python.pythonPath`, for example, traverse the template's nested objects; an empty
section receives the entire settings object. The host also sends the initial
configuration after initialization. Literal server-specific behavior, such as
ty's `experimental.useUv = off`, belongs in the plugin template.

The host bounds manifests to 64 KiB, services to 8 per package, choices to 8 per
service, argument arrays to 32, JSON nesting to 12, and project-root searches to
64 ancestors. Relative paths reject traversal/absolute paths. Unknown declaration
keys, missing defaults, undeclared language IDs and duplicate IDs are rejected.
The concrete host model remains authoritative for validation.

These contributions attach services to editor language IDs. Runtime merging of
new syntax definitions/lexers remains a separate feature. This declarative
runtime has no commands or executable module and needs no native C ABI extension.

## Activation and process ownership

`ExtensionWorkspaceUseCase.languageServerRegistrations()` emits only enabled,
identity-bound, authorized package snapshots. `onLanguageServicesChange` updates
the common completion provider. Persisted authority is checked before semantic
requests and before accepting results, including across windows that have not
refreshed their registries yet. Competing enabled providers for the same language
are quarantined and reported in Language Support preferences.

The helper independently verifies the original signed inventory, package digest,
service definition and API compatibility before root discovery or server launch.
A request cannot replace the command, settings template, interpreter rule or
language while reusing another package's signature. Publisher keys must already
be recognized by the existing package trust policy. `language.servers` authorizes
launching an external server through the host; those server processes use the
existing unsandboxed, authenticated helper and can read project files. This is
not a filesystem sandbox for the external language server.

Disable, uninstall, publisher revocation, changed registrations, settings changes
and window shutdown invalidate pending work, stop connections and clear resolved
candidates. Document/keyword completion and Lexilla syntax support continue with
no language plugin. Removing a plugin retains project files/environments and
machine-local language settings. Other windows refresh when policy generation
changes; a persisted-policy check already rejects stale authority before refresh.

## Settings and environments

Preferences → Language Support renders the choices from active registrations.
Its scopes are **All defaults**, **Current workspace** (the initial choice), and
**Selected folder**. The folder picker lists the registered roots; a standalone
file also offers its detected project folder. The interpreter field appears only
when the plugin declares an interpreter rule. Disabled is a server choice.

Settings are stored under `<extensionID>/<languageID>` in the existing AppSettings
archive. `workspaces[SessionID UUID]` owns the workspace overrides and its
`folders[WorkspaceRootID UUID]` owns registered-folder overrides. Standalone
projects use `path:<absolute project root>` inside that workspace. The session ID
is restored by existing window recovery. Two windows opening the same physical
folder therefore keep independent selections. No interpreter path is written
into the user's project. Legacy project-path entries are copied into each
workspace on first use; a persisted empty snapshot prevents cleared selections
from being imported again.

Interpreter precedence is explicit folder selection, explicit workspace selection,
the plugin's automatic project paths (for example `.venv/bin/python`), the global
default, then executable-name discovery. Server precedence is folder, workspace,
global default, then the plugin default. Explicit invalid interpreter paths fail
instead of silently selecting a different environment. Virtual-environment
symlinks are preserved. Environments and project packages are not created or
installed automatically. The host has no Python-specific runtime adapter or
settings page.

Launch packets contain only the owner's workspace settings. Session/root-cache
keys include workspace and folder identities. Settings publication compares each
provider's own projection, so changing another workspace preserves its active
connection and candidates. Root association changes and plugin authority changes
still invalidate affected providers and fence pending results. Python, Ruby and
Rust plugins all use this same host interface; a plugin manifest does not need
workspace-specific fields.

Server discovery searches declared project executable directories, the common
`~/Library/Application Support/Duckpad/LanguageServers/bin` location, conventional
version-manager shims, `~/.local/bin`, `~/.cargo/bin`, Homebrew and system paths.
There is no login-shell evaluation or generic plugin command-execution API.
Installation hints are guidance; automatic server downloads are not implemented.

## Verify and sign the reference packages

```sh
swift scripts/build_language_plugins.swift
```

The default operation verifies inventories and Ed25519 signatures without
rewriting files. Signing requires `--signing-seed /absolute/external/seed` with a
0600 raw Ed25519 seed. `--create-key` is explicit and only creates a missing seed;
it never rotates an existing publisher. The language-support publisher has
its own key, separate from Text Tools and Clipboard. Its private seed is outside
the worktree; only the public key, manifests, inventories and signatures ship in
source.

The independently released [Python](https://github.com/namJeongwan/duckpad-plugin-python),
[Ruby/Rails](https://github.com/namJeongwan/duckpad-plugin-ruby) and
[Rust](https://github.com/namJeongwan/duckpad-plugin-rust) packages are version 0.1.0
and listed in the official catalog for host API 1.5.0. Install from Available
Plugins, or extract a release ZIP and select its `.duckpad-plugin` folder with
Install Plugin. Language server binaries remain separately installed tools.
