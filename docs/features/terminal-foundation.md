# Integrated terminal

The terminal icon at the left edge of the status bar or View → Terminal (Control-backtick) opens a resizable bottom panel. The icon is followed by compact, right-aligned document information. The panel supports window-local sessions displayed as tabs without an artificial session-count limit, with active underlines, hover feedback and individual close buttons. Session tabs share document-tab colors and the multiline/close-button preferences. Narrow panels wrap tabs; single-line mode scrolls to the selected session. Switching tabs preserves each running shell. Hiding it preserves shells and panel height; Control-backtick hides it; Command-W closes the focused terminal pane without closing a document.

New sessions launch `/bin/zsh -l` in the current terminal's reported working directory, otherwise the active document's folder, the first workspace folder, or the account's actual home directory. Existing sessions keep their working directories. Shell configuration and command permissions behave as a user-level terminal. Closing a running session or a window with running sessions requires confirmation. Sessions are not restored across app restarts.

Ghostty 1.3.1 supplies the terminal parser, scrollback, fonts and Metal rendering. The Swift AppKit adapter supplies keyboard/IME composition, selection, copy/paste, scrolling, focus, resize, terminal search and the native engine inspector. A session can contain up to sixteen terminal panes. The unmodified bundled zsh integration supplies prompt markers and working-directory reporting. Ghostty initializes only on the first terminal request; creating an editor window does not create a terminal engine or shell. Terminal appearance currently uses a fixed dark palette. OSC clipboard access is disabled; explicit Copy/Paste is available. Custom shells are not supported yet. Command-comma opens Duckpad’s own terminal.conf in Application Support; Command-Shift-comma reloads it. The separately installed Ghostty app and its personal configuration are not required or loaded.

The editor keeps its existing App Sandbox entitlements. A dedicated `DuckpadTerminalHost.xpc`, authenticated against the containing app's code identity and user ID, creates each PTY and login shell outside the sandbox. It passes the PTY descriptor over XPC. A small pinned Ghostty backend patch duplicates that descriptor and uses its existing read/write threads. No relay process, local terminal shell, privileged helper, or installer API is involved. Process exit uses the authenticated XPC connection. PTY resizing stays in Ghostty’s IO thread, keeping SIGWINCH and terminal grid updates ordered; font zoom also updates shell dimensions without waiting for a window resize. Closing the connection terminates the foreground job and hangs up the login shell, with forced termination if needed. Terminal layout undo retains closed panes for five seconds, independently of document undo; expired history and window teardown release the connections.

The helper's post-fork path is C/POSIX only. Swift/Foundation do not execute between fork and exec. The launch error pipe distinguishes failed exec from a running process. The engine owns its duplicated descriptor; the connection owns the original descriptor and shell lifetime.

Build prerequisites: Xcode, its Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`), and network access on the first build. Run `scripts/build_ghostty.sh --architecture native` before direct SwiftPM commands. App packaging runs this automatically. The script pins Ghostty and verifies the Zig 0.15.2 download hash. `universal` builds both macOS architectures. Generated tools, SDK copy and library remain in ignored build directories.

Validation: focused application/presentation tests cover lazy creation, session lifetime, hide/reopen, close routing, resizing and localization. `python3 tests/terminal/test_pty.py` checks failed exec, UTF-8, working directory, PTY resizing, Ctrl-C and exit/reaping. Packaged Apple Silicon UI checks exercise the actual Ghostty surface, shell execution, UTF-8 output, Ctrl-C, hide/reopen, resize, Vim alternate-screen entry/return and termination of a running foreground command. All eight localization resource sets pass validation; the new engine exit message has only been inspected in English. Physical Korean IME interaction, Intel runtime and full terminal accessibility have not been verified.

## Keyboard routing

The embedded Ghostty 1.3.1 macOS default bindings are retained directly; there is no duplicated hand-maintained keymap and no `keybind = clear`. Binding detection uses `ghostty_surface_key_is_binding` before Duckpad menu equivalents. The window and local close-key router consult the focused terminal, including its search field. Modal dialogs retain their own shortcuts. Editor focus restores the original Duckpad routing.

| Keys | Terminal focus | Conflicting Duckpad behavior |
| --- | --- | --- |
| Command-N / T | New window with terminal / new session tab | New scratch document / document tab actions |
| Command-W | Close focused terminal pane | Close editor document; previous terminal implementation hid the panel |
| Command-Option-W / Shift-W | Close terminal tab / window | Editor close commands |
| Command-D / Shift-D | Split right / down | Duplicate line / editor commands |
| Command-[ / ] and Command-Option-arrows | Focus terminal split | Editor navigation |
| Command-Control-arrows / Command-Control-= | Resize / equalize splits | Editor layout bindings |
| Command-Shift-Return | Zoom focused split | Editor commands |
| Control-Tab / Shift-Control-Tab, Command-Shift-[ / ], Command-1…9 | Switch terminal sessions | Switch document tabs |
| Command-F / G / Shift-G / E / Shift-F, Escape | Terminal search/navigation/selection/end | Document search; Find in Files |
| Command-Z / Shift-Z / Shift-T | Terminal layout undo/redo (five-second history) | Document undo/redo/reopen |
| Command-Shift-P | Terminal command palette | Duckpad command palette |
| Command-C / V / A | Terminal copy/paste/select all | Document editing |
| Command-H / Option-H / M | macOS hide / hide others / minimize | Duckpad Replace uses Command-H |
| Control-W | Forward to shell (delete word) | Duckpad auxiliary-panel close router |

Font size, screen clearing, scrollback, selection adjustment, prompt jumps, line navigation, screen-file export and other engine-owned bindings execute in Ghostty. The host implements split/session/window actions; Command-Q retains Duckpad’s normal quit and unsaved-document review. Command-Option-I opens the engine inspector. The engine’s paste confirmation remains enabled; explicit clipboard operations do not enable OSC 52 clipboard access.

The terminal palette is a compact in-window overlay with single-line commands and macOS default shortcut labels. It supports immediate filtering, arrow keys, Return, Escape, single-click execution and outside-click dismissal; focus returns to the terminal after dismissal. Its bounds follow the host window, including narrow windows. UI geometry and document tabs remain Duckpad-owned; terminal shortcuts never use the document undo manager. Hiding the panel is a Duckpad addition (Control-backtick). Physical IME and every non-US keyboard layout still require manual validation.

Terminal session context menus support closing the clicked tab, tabs to its left/right, all other tabs, or every tab. A bulk close has a single confirmation and a single terminal Undo step. Close confirmations offer a terminal-only “don’t ask again” preference; the context-menu “Confirm Closing Terminal Sessions” item restores prompting. Cancelling never changes the preference or closes a subset. The tab strip has no trailing add/hide buttons; Command-T creates a session even after closing the last one, and Control-backtick toggles the panel.

Screen changes update the Ghostty-hosted layer's contentsScale and framebuffer dimensions together, without implicit Core Animation scaling. The initial placeholder is hidden while an engine surface exists, preventing stale “shell not connected” content from showing through the renderer during display transitions.


Terminal display regression checks (2026-10-17, Apple Silicon):

- In a fresh session, split right before creating any other panes. Both panes must remain visible after engine startup and window resize. The previous build collapsed the first pane to zero width; seeding both child frames before attaching them keeps the initial split balanced. This is also covered by `firstSplitKeepsBothPanesVisibleAfterLayout`.
- Run `stty size`, press Command-plus three times, then run it again without resizing the window. Before the IO fix, the shell stayed at 11 rows / 126 columns and the prompt wrapped incorrectly. With the fixed packaged app, it changes to 9 / 98, and Command-zero restores the normal size. Exact counts depend on the window and font.
- Resize the window and split a new session. The packaged app reports updated shell dimensions (11 / 126 to 11 / 154 on window widening; 11 / 61 in a half-width pane) and preserves prompt rendering.
- Move the same live session between 1x external displays and the 2x built-in display, preserving output and point-sized glyphs. The initial scale defect was reproduced on external displays, but only the built-in Retina display was connected for the final build. Final external-display round trips remain unverified.

The final focused presentation run passes 16 tests in four suites. Session close menus and the suppression checkbox were inspected in English; all eight locale resources pass string/format validation. Package resource, XPC isolation and signature verification pass for the native preview build.
