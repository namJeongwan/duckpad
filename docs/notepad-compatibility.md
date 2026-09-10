# Notepad++ compatibility

Duckpad follows Notepad++ terminology and menu grouping while using native macOS controls and Command shortcuts. Macro recording is intentionally excluded. This is a compatibility inventory, not a claim of complete feature parity.

Reference: [Notepad++ user interface](https://github.com/notepad-plus-plus/npp-usermanual/blob/master/content/docs/user-interface.md) and [Preferences](https://github.com/notepad-plus-plus/npp-usermanual/blob/master/content/docs/preferences.md).

## Menus

The document menu bar and macOS menu bar share File, Edit, Search, View, Encoding, Language, Preferences, Tools, Plugins, Window, and Help. Preferences replaces Settings at the user's request. Tab navigation lives under Window; bulk tab closing lives under File > Close More. Editing commands are grouped under Line Operations, Convert Case to, and Blank Operations. Symbol visibility and zoom commands have View submenus.

Encoding and EOL conversion currently save the document through the existing protected save flow; EOL conversion is explicitly labelled accordingly. Notepad++ can change encoding/EOL in an unsaved buffer. Duckpad supports UTF-8 and UTF-16 variants, not the complete Notepad++ legacy code-page list.

Run, printing, hash tools, configurable shortcuts, custom style themes, and the full Notepad++ command inventory are not implemented. Their menus are not represented by inert controls. Windows shell integration and Windows-only preferences do not apply to macOS.

## Preferences

Preferences uses a category list, immediate application, persistent storage, and rollback on failed storage. Existing settings files remain readable.

| Category | Working controls |
| --- | --- |
| General | Document-window menu bar; status bar |
| Tab Bar | Tab drag and drop; close buttons; buttons on inactive tabs |
| Editing | Current-line highlight; caret width and blink rate; default/aligned/indented wrapping; scrolling beyond the last line; virtual space |
| Dark Mode | Light Mode, Dark Mode, Follow macOS |
| Margins/Border/Edge | Line numbers; bookmark margin; vertical edge and column |
| New Document | Default word wrap and wrap symbols |
| Default Directory | Last used location or active document directory for Open/Save As |
| Recent Files History | Maximum visible entries; file name/full path/disambiguated display |
| Searching | Fill from selection; maximum auto-fill length; monospaced Find/Replace fields |
| Indentation | Override language defaults; tab size; tabs/spaces; indent guides |

The complete Notepad++ Preferences inventory is larger. Toolbar icon sets, further tab options, Editing 2, default document encoding/EOL, custom default directory, language overrides, per-language indentation and auto-indent modes, highlighting options, print, further search defaults (caret word and automatic selection scope), backup configuration, auto-completion configuration, date formats, delimiters, performance configuration, cloud/link configuration, search engines, and miscellaneous toggles remain separate feature work. Session recovery, searching, language detection, indentation, and completion already have implementations; this does not mean their full Notepad++ configuration interfaces exist.

## Duckpad additions and differences

- Split a workspace in any of four directions using a tab drag. Groups are created as needed; there is no four-group cap. Notepad++ provides two document views.
- Command Palette searches available commands.
- Built-in, read-only comparison opens a separate resizable diff window with aligned rows and synchronized scrolling. Notepad++ normally provides comparison through a plugin.
- Plugins run through Duckpad's WASM/XPC architecture. Windows Notepad++ DLL plugins are not binary-compatible.
- Native macOS file authorization, appearance, window controls, and shortcuts are platform adaptations.

Session restoration, pinned tabs, multiple tab rows, word wrap, bookmarks, syntax highlighting, and document/function lists are not exclusive Duckpad features.
