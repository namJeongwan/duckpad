#!/usr/bin/env python3
"""Small macOS-only host PTY adapter; upstream owns parsing and rendering."""
from pathlib import Path
import subprocess, sys
source = Path(sys.argv[1])
path = 'src/termio/Exec.zig'
s = subprocess.check_output(['git', '-C', str(source), 'show', '332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28:' + path]).decode()
s = s.replace('        .flatpak => null,', '        .flatpak => null,\n        .host => null,', 1)
s = s.replace('            .fork_exec => {},', '            .fork_exec, .host => {},', 1)
s = s.replace('        fork_exec: Command,', '        fork_exec: Command,\n\n        /// Duckpad owns the process through its authenticated XPC service.\n        host: void,', 1)
marker = '        assert(self.pty == null and self.process == null);'
s = s.replace(marker, marker + '''

        if (comptime builtin.target.os.tag == .macos) {
            if (self.env) |*env| {
                if (env.get("DUCKPAD_HOST_PTY_FD")) |value| {
                    const original = try std.fmt.parseInt(posix.fd_t, value, 10);
                    if (original < 0) return error.InvalidHostPty;
                    const fd: posix.fd_t = @intCast(try posix.fcntl(original, posix.F.DUPFD_CLOEXEC, 0));
                    self.pty = .{ .master = fd, .slave = -1 };
                    self.process = .{ .host = {} };
                    env.deinit();
                    self.env = null;
                    return .{ .read = fd, .write = fd };
                }
            }
        }
''', 1)
s = s.replace('        switch (self.process orelse return) {', '        switch (self.process orelse return) {\n            .host => {},', 1)
# Keep upstream PTY resizing on its IO thread so SIGWINCH cannot race terminal
# grid updates. The host owns process exit detection; no local termios polling.
s = s.replace('    if (comptime builtin.os.tag != .windows) {\n        termios_timer.run(', '    if (comptime builtin.os.tag != .windows) {\n        if (self.subprocess.process.? == .host) return;\n        termios_timer.run(', 1)
(source / path).write_text(s)
