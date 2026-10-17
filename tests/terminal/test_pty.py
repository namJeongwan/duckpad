#!/usr/bin/env python3
"""Bounded integration checks for the C PTY boundary, without user shell files."""
import ctypes
import errno
import fcntl
import os
from pathlib import Path
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='duckpad-terminal-test-') as temporary:
    temporary = Path(temporary)
    library = temporary / 'pty.dylib'
    subprocess.run(['clang', '-dynamiclib', '-Wall', '-Wextra', '-Werror',
                    '-I', str(root / 'Sources/DuckpadTerminalBridge/include'),
                    str(root / 'Sources/DuckpadTerminalBridge/TerminalPTY.c'), '-o', str(library)], check=True)
    bridge = ctypes.CDLL(str(library), use_errno=True)
    spawn = bridge.dp_terminal_spawn
    spawn.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.POINTER(ctypes.c_char_p),
                      ctypes.c_uint16, ctypes.c_uint16, ctypes.POINTER(ctypes.c_int)]
    spawn.restype = ctypes.c_int
    env = (ctypes.c_char_p * 6)(b'PATH=/usr/bin:/bin:/usr/sbin:/sbin',
                               ('HOME=' + str(temporary)).encode(),
                               ('ZDOTDIR=' + str(temporary)).encode(), b'TERM=xterm-256color', b'LANG=en_US.UTF-8', None)
    pid = ctypes.c_int()
    assert spawn(b'/bin/zsh', b'/nonexistent-duckpad-pty-test', env, 24, 80, ctypes.byref(pid)) == -1
    assert ctypes.get_errno() == errno.ENOENT
    fd = spawn(b'/bin/zsh', str(temporary).encode(), env, 24, 80, ctypes.byref(pid))
    assert fd >= 0, os.strerror(ctypes.get_errno())
    def read_until(marker, timeout=8):
        output = b''
        deadline = time.monotonic() + timeout
        while marker not in output and time.monotonic() < deadline:
            if select.select([fd], [], [], max(0, deadline - time.monotonic()))[0]:
                output += os.read(fd, 65536)
        assert marker in output, repr(output[-1000:])
        return output
    try:
        os.write(fd, b"stty -echo; printf '\\nREADY_%s\\n' PTY\n")
        read_until(b'READY_PTY')
        os.write(fd, "printf '한글 UTF-8\\n'; pwd; stty size; printf 'CHECK_%s\\n' ONE\n".encode())
        output = read_until(b'CHECK_ONE')
        assert '한글 UTF-8'.encode() in output
        assert str(temporary).encode() in output
        assert b'24 80' in output
        fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', 37, 111, 0, 0))
        os.write(fd, b"stty size; printf 'CHECK_%s\\n' TWO\n")
        assert b'37 111' in read_until(b'CHECK_TWO')
        os.write(fd, b"printf 'SLEEP_%s\\n' START; /bin/sleep 30\n")
        read_until(b'SLEEP_START')
        time.sleep(.1)
        os.write(fd, b'\x03')
        os.write(fd, b"printf 'CHECK_%s\\n' INTERRUPT\n")
        read_until(b'CHECK_INTERRUPT')
        os.write(fd, b'exit\n')
        exit_output = b''
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            result, status = os.waitpid(pid.value, os.WNOHANG)
            if result:
                assert os.WIFEXITED(status)
                pid.value = 0
                break
            if select.select([fd], [], [], .05)[0]:
                try: exit_output += os.read(fd, 65536)
                except OSError as error:
                    if error.errno != errno.EIO: raise
        assert pid.value == 0, 'shell failed to exit: ' + repr(exit_output)
    finally:
        os.close(fd)
        if pid.value > 0:
            os.killpg(pid.value, signal.SIGKILL)
            os.waitpid(pid.value, 0)
print('PASS: exec failure handshake, UTF-8, cwd, PTY size/resize, Ctrl-C, exit/reaping')
