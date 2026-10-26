# Tail and SSH file viewing

This feature adds read-only observation of local and SSH files. It does not
change the normal editable file-open or Save behavior.

## User workflow

- Open a UTF-8 local file, then choose **View → Tail Mode**. Unsaved documents
  must be saved or reverted first. Appends follow the end only while the pane
  was already there; scrolling up pauses following without pausing collection.
- The Tail bar provides Follow End, Clear Output and Stop. Clear Output changes
  only the observed view, never the source file. Returning a local file to
  editable mode requires a successful complete refresh from disk.
- Choose **File → Open Remote File…**, select a recent/configured SSH host or
  enter a destination, then Connect. The reusable browser opens the remote home
  directory unless a path was entered or a recent folder was remembered.
  Connect establishes the host connection before trying that path. An invalid,
  missing or inaccessible folder leaves the host connected, preserves the input
  and last usable listing, and reports a folder error without reconnect retries.
  Correct the path and use Return or Refresh to continue on the shared connection.
- Double-click folders, use Parent/Refresh, or enter an absolute path. Folder
  completion uses the loaded directory. Toggle hidden files in the browser.
  Select a file for a bounded preview, or select multiple files and Open.
  The browser stays open for further selections. Enable Tail before opening to
  follow those files. Remote snapshots are read-only; Save, Rename, Move and
  Trash do not operate on the remote file.
- The default SSH connection uses the user's OpenSSH configuration, keys and
  agent. Password prompts are disabled. A new host must first be trusted in
  Terminal; Duckpad does not accept unknown host keys automatically.

## Implementation boundaries

The application sandbox delegates bounded SSH reads to the existing signed,
user-validated terminal XPC helper. Structured requests contain a destination,
path, cursor and read limit. The helper constructs the remote command and uses
system `/usr/bin/ssh`; no shell command is accepted from the client.

Local reads use `pread` against a regular-file descriptor. Remote reads open the
file once, stat that descriptor and read a bounded byte range. The protocol
supports the macOS/BSD and GNU `stat` forms and requires POSIX shell, `tail` and
`head` on the server. A new inode or a size below the cursor resets the view.
Copy-truncate followed by regrowth beyond the previous cursor between polls is
not distinguishable from an ordinary append with this polling protocol.

Tail publishes at most 64 KiB per native append. It keeps incomplete UTF-8 bytes
until the next read, preserves each split pane's selection and viewport, and
updates recovery revisions without producing user edits or Undo entries. It
never reads a whole-document editor snapshot on the append path. A rotation or
Clear Output releases the previous observation journal.

Local polling defaults to 250 ms; remote polling defaults to one second. Server
latency is separate from the native append latency. A single authenticated
helper session shares one foreground-owned OpenSSH control master per host and
SSH configuration across browsing, previews, snapshots and Tail. At most eight
commands use a host concurrently; excess requests wait and remain cancellable.
Unused connections expire after 60 seconds. Cancelling one command does not
cancel another file. App disconnect shuts down the owned masters; a dead control
socket cannot silently fall back to a second connection. A later request or
Retry establishes a new connection. A regular remote snapshot is limited to
64 MiB; starting remote Tail loads the latest 1 MiB. The current observation may
grow by 64 MiB before Clear Output is required. Recovered Tail tabs start paused
and reconnect only when the user requests Follow End.

## Reference

The local Emacs checkout was inspected for byte-offset tail reads, file identity
changes, following only windows already at the end, and SSH connection sharing
(`lisp/autorevert.el`, `lisp/net/tramp.el`, `lisp/net/tramp-sh.el`). This Duckpad
implementation is independent; the reference checkout was not modified.

## Validation

Validation covers bounded local/remote protocol reads, hostile path quoting,
process timeout/cancellation, split UTF-8, rotation/truncation, dirty-state and
transaction cancellation, shared panes, recovery revisions, localized controls
and native append latency. The packaged SSH smoke uses an isolated localhost
server, temporary host/client keys, a separate known-hosts file and isolated app
recovery state; it does not change the user's SSH files or production servers.
Actual results and remaining verification limits are recorded in the task's
completion report.

### Phase 1 validation, 2026-10-21

The final focused run passes 17 test functions plus parameter cases. Related
live reload, binary read-only, recovery and Tail performance runs pass nine
functions. Both POSIX sh and zsh execute the quoted read protocol successfully.
On Apple Silicon, a 17,500,000-byte shared document with the minimap enabled
renders 48,000-byte appends in 2.99 ms initially and at most 3.58 ms over twelve
samples. These measurements cover native append/layout/display, not network
latency or every possible file shape.

The ad-hoc signed native app passes bundle verification and the standard
Finder/Open With, resize, XPC extension/isolation and ripgrep smoke checks.
Native save-panel automation was skipped. An isolated macOS OpenSSH server
verifies the packaged sandbox-to-helper path, temporary SSH config/key and host
trust, remote open, split-byte Korean/emoji Tail, invalid-key rejection and
cleanup of an active SSH child after the app disconnects. No user SSH files were
modified. Intel hardware, external production servers, Linux server execution
and physical Korean IME interaction were not verified. This is a development
preview, not a notarized release.

Machine-readable results: [tail-and-remote-files-validation.json](tail-and-remote-files-validation.json).

## Phase 2: browsing and shared connections

The browser lists literal `Host` aliases and bounded `Include` files without
executing `Match exec` during discovery. OpenSSH itself remains responsible for
actual connection configuration. Discovery inspects at most 64 regular files (at most 1 MiB plus one limit-check byte per file) and
8,192 include-directory entries, with a 4 MiB budget for parsed configuration.
Private keys and special files are not read. Unresolved SSH tokens/environment substitutions are left to
OpenSSH and are not expanded for alias discovery.

A directory response contains up to 5,000 entries and 2 MiB of framed UTF-8.
Names containing control characters or invalid UTF-8 cannot be represented and
are omitted. The file preview reads at most 16 KiB. A truncated directory is
explicitly labelled; entering an exact absolute file path still works.
Recent hosts (12) and their last directories are stored locally, without
credentials. Password authentication remains outside this phase.

Late/cancelled directory and preview responses cannot overwrite newer selection
or typed paths. Large snapshots already published to the editor finish their
accepted native load before termination/recovery review proceeds. Scrolling up
in Tail keeps collecting output and displays the number of newly completed
lines; Follow End clears that count. File rotation clears the old count.

ANSI colors, automatic log-format detection and log-level highlighting are
reserved for phase 3. This phase keeps the original text unchanged.

### Phase 2 validation, 2026-10-22

Twenty-four distinct test functions pass across the focused Release runs,
including both opt-in real SSH tests. The final backend run passes eight
functions: one TCP transport serves browsing and multiple reads, twelve
concurrent commands respect the channel limit, cancelling one leaves others
usable, idle expiry reconnects, and shutdown waits even for a master already
removed by expiry. A gate holds the final worker completion to verify that
shutdown cannot return early. No owned SSH children remain after the tests.
Native termination, late browsing responses, unread-line reset and eight-language
control geometry pass. Localization verification passes 1,223 strings and five
plural entries in all eight languages. Native Tail append/layout/display on the
17,500,000-byte document measures 2.69 ms first / 3.99 ms maximum over twelve
48,000-byte appends; this excludes network time.

The final native preview is `build/tail-phase2-final/Duckpad.app`, version
0.14.3 (65), ad-hoc signed and not notarized. It passes bundle verification,
Finder/Open With, resize, sandboxed extension/isolation and ripgrep smoke checks.
An initial general smoke run concurrent with SSH testing hit the existing
extension-isolation cancellation assertion; the serial final-app run passes.
Native save-panel automation remains skipped.

The packaged sandbox-to-helper SSH flow verifies aliases, directory listing,
preview, multiple snapshots and split-byte Korean/emoji Tail over exactly one
authenticated transport. Invalid keys are rejected. Both normal app disconnect
and disconnect during a blocked SSH handshake leave zero owned SSH children.
The isolated server, keys/config/known-hosts and recovery state are removed after
validation; user SSH files are unchanged. Source changes have independent review
approval with no remaining Blocker/Major findings.

Intel, external servers, Linux execution and physical IME interaction remain
unverified. Manual screenshot inspection could not run because computer-use
onboarding was unavailable; native automated geometry checks cover eight
languages. No release, version bump or Git integration is performed in this
phase.

## Phase 3: log colours

[Log highlighting](log-highlighting.md) adds common automatic log detection and
byte-preserving ANSI/log-level styling to local, remote and Tail documents.
Phase 1/2 validation above remains historical; phase 3 has separate evidence.

## Filtered destinations and bounded reconnect

The host and directory inputs share a live suggestion component. Typing filters
by case-insensitive substring without completing or replacing the typed value.
Korean marked text also filters immediately. Opening the disclosure shows the
catalogue; arrow keys or a click explicitly select a suggestion. Return uses
the exact typed destination unless the user has selected a suggestion. A late
host catalogue preserves that selection, and changing servers clears the old
server's directory suggestions. The popup retains input focus and supports
Escape and outside-click dismissal.

SSH browsing, preview reads, snapshot reads and remote Tail retry transport
failures up to three times, waiting 1, 2 and 4 seconds between attempts (four
requests including the original). OpenSSH's existing exit-255 error mapping
includes authentication and disconnected transports, so both receive this
bounded policy; host/key verification is unchanged. Cancellation, invalid
responses, decoding errors and size limits do not trigger connection retries.
Successful Tail reads reset the consecutive-failure counter. Local Tail keeps
its existing polling policy.

The browser shows reconnect progress and returns to a manual Retry action after
exhaustion. The Tail bar also offers Retry after an exhausted connection failure.
Manual and automatic Tail reconnect load the latest approximately 64 KiB in a
single replacement and resume Following at the end, rather than replaying the
backlog from the old offset. A metadata read locates the end; one bounded read
loads the current window. A cut first line is discarded where possible, and
incomplete UTF-8 at the end is retained for the next append. The previous
snapshot remains readable until replacement succeeds. Successful replacement
clears unread counts and restarts the bounded growth budget; subsequent appends
still enforce the 64 MiB limit. Stop, cancellation, changing servers,
closing the browser or closing a Tail tab cancel outstanding retry waits.

Original filter/retry validation: 26 distinct focused test functions passed, including reconnect
exhaustion/cancellation, incomplete Korean UTF-8 and the 64 MiB growth limit.
Eight-language resources and
control geometry pass; native light/dark filter captures were inspected. The
arm64 development preview passes bundle verification and general app smokes;
native save-panel automation was skipped. Independent review has no remaining
Blocker/Major findings. Physical IME, Intel and real network outage testing
were not performed for this change. Details: [remote-filter-and-retry-validation.json](remote-filter-and-retry-validation.json).

Reconnect regression validation (2026-10-23): all 16 focused Release test
functions completed across RemoteReconnectTests, RemoteRetryBudgetTests,
FileTailUTF8DecoderTests and TailRemoteIntegrationTests. A 3,000,014-byte local
fixture backlog required exactly two reads and a 65,502-byte replacement;
measured reconnect-to-Following times were 6.07 ms (append) and 7.20 ms (rotation).
These are local fixture measurements, excluding SSH network latency. Empty
files, rotation between metadata and content reads, incomplete Korean UTF-8,
late cancelled replies, read-only/Undo/recovery state and the subsequent 64 MiB
growth limit are covered. Live network outage and release-package validation
were not run for this follow-up.

The destination popup now shows up to 12 rows at 32 points per row with
6-point outer padding. It chooses the available space above or below the
field and stays inside the visible screen. Six focused filter tests and native
light/dark captures pass; the new native preview passes bundle verification.

The remote browser uses the shared Workspace/Find panel, editor, divider and
selection colours in light and dark appearances. Its scrollbars use the same
autohiding overlay style. **Control–Command–O** opens the remote browser; this
command participates in the normal shortcut settings, conflict detection and
command palette. Existing Command–Shift–O document switching and
Command–Option–O symbols remain assigned to their original commands.

Inside the remote browser, Command–L focuses the path, Command–Shift–L focuses
the host, Command–R refreshes, Command–Up opens the parent directory and
Command–W closes the browser. These commands are scoped to the browser window:
refresh and close do not activate the editor's Replace or Close Tab actions.
Keyboard matching uses the existing ASCII-capable layout normalization, also
while Korean input is selected. Field tooltips display the relevant shortcuts.

The shared search input supplies a subtle hover background/border and a neutral
focus outline without changing field geometry, the editor, selection or IME
composition. Disabled inputs do not react. Remote navigation, suggestion
disclosure and Tail toolbar icons use the existing `StatusBarButton`. Connect,
Cancel and Open continue to use `SearchActionButton`; its hover, pressed and
disabled chrome now applies consistently to all consumers, with native button
tracking and actions retained. Checkboxes retain native checkbox semantics.

Dropdown hover/focus chrome covers the complete composite input, including its
arrow, without a nested input outline or blue focus border. The shared search
surface resolves neutral interaction colours in both appearances. Tail and
remote navigation icons use `StatusBarButton.configureAsToolbarIcon` for common
symbol sizing and alignment; Tail actions have a 28 by 24 point hover/click area
and are vertically centered in the 28 point bar.

Toolbar icon buttons also override native alignment insets only in this mode.
AppKit's symbol-dependent insets otherwise expanded nominal 24-point heights to
28–31 points, placing hover outside the bar. Native before/after probes verify
that all four symbols now have equal 28 by 24 point frames, centered with two
points above and below. Other status buttons retain their native alignment.

Suggestion rows reuse `CommandPaletteRowView` hover chrome, including SSH host
and remote folder suggestions. Hover is visual only: it preserves the query,
IME editor and keyboard selection. Remote host/path rows use fill distribution
with flexible input hugging, keeping their labels aligned while the fields
consume remaining width before the fixed action buttons. Path widths measured
530.5, 610.5 and 910.5 points in 720, 800 and 1100 point windows respectively.
