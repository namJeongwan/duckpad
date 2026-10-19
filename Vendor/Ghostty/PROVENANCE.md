# Ghostty

2026-10-19 inspector localization: `scripts/patch_ghostty_inspector.py` wraps
static Inspector labels and complete help expressions with a host-owned UTF-8
translation callback. The reviewed key inventory is stored in
`inspector-localization-keys.json` and validated against all eight Swift catalogs.
Internal ImGui IDs, protocol field names, terminal contents, and user data are
preserved. A supplemental system font supports CJK glyphs through Dear ImGui
1.92's dynamic atlas. The unrelated upstream ImGui demonstration is no longer
opened by default. Locale changes recreate only open inspector views/atlases,
preserving terminal sessions. The callback patch, inventory, and script are part
of the framework build cache key; no generated framework is committed.

- Source: https://github.com/ghostty-org/ghostty
- Version: v1.3.1
- Commit: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- License: MIT, retained in `LICENSE`.
- Build: `scripts/build_ghostty.sh --architecture native|universal`, Zig 0.15.2.
- Generated `GhosttyKit.xcframework` is ignored; builds use pinned source.

Build adjustments are applied to the ignored source checkout by the script:
exclude the unused VT shared library and iOS variants from the install step;
use Zig's bundled libSystem stub in a private SDK copy for recent macOS SDKs;
repack Zig archives through extracted object files for Apple's newer libtool,
which otherwise discards unaligned archive members. The SDK root is resolved
before copying versioned aliases, and stale destination symlinks from earlier
builds are removed. Installed SDKs are not modified. Sentry crash reporting is
disabled in this embedding.

`scripts/patch_ghostty_host_pty.py` adapts `src/termio/Exec.zig` for a host-owned
macOS PTY. `DUCKPAD_HOST_PTY_FD` is provided by the Swift surface configuration.
The engine duplicates this descriptor, uses its existing IO threads, and skips
local process creation and process watching for that session. The initial termios
timer is skipped, but upstream focus-triggered polling remains enabled on the
master descriptor to preserve password-entry detection.
The XPC host handles process lifetime. The engine retains upstream PTY resizing
on its IO thread, including pixel dimensions and SIGWINCH ordering relative to
terminal grid updates. Swift does not send a separate, earlier XPC resize. The
normal upstream execution path is preserved. No terminal parsing or rendering code is changed.

`GhosttySurfaceView.swift` follows the keyDown/preedit/insertText ordering from
`macos/Sources/Ghostty/Surface View/SurfaceView_AppKit.swift` at the above revision.
Original AppKit key events are retained for IME handling.

Packaging collects notices from the downloaded dependency sources, including
embedded fonts, into `ThirdPartyLicenses/GhosttyDependencies`. Dependency source
hashes are pinned by Ghostty's manifests. Distribution must retain corresponding
licenses and satisfy applicable source/relinking obligations.

`GhosttyInspectorView.swift` follows upstream Metal inspector rendering.
`GhosttyInspectorKeys.swift` derives the macOS key-code mapping from
`macos/Sources/Ghostty/Ghostty.Input.swift` at the pinned revision (MIT).
The packaged upstream zsh shell-integration scripts run unmodified to provide
prompt marks and working-directory reporting; their individual license headers
and collected notices remain in the distribution.

Ghostty statically links libintl from GNU gettext 0.24 (LGPL). Its notice is
retained at `GhosttyDependencies/<pinned-hash>/gettext-runtime/intl/COPYING.LIB`.
To replace that library, remove `.build/ghostty-build-native.stamp` and
`.build/ghostty-build-universal.stamp` so the generated-framework cache cannot
skip rebuilding the changed dependency. Rebuild Ghostty from the pinned source
and dependency manifest using `scripts/build_ghostty.sh --architecture universal`, then relink
Duckpad with `scripts/build_macos_app.sh --architecture universal`. The public
source, host-PTY patch and build scripts provide the corresponding rebuild path.
