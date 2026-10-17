#!/usr/bin/env python3
"""Close a packaged terminal running yes; needs macOS Accessibility permission.

Uses a separate recovery namespace and targets only the process it launches.
Usage: python3 tests/terminal/smoke_noisy_shutdown.py /path/to/Duckpad.app
"""
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import uuid

app = Path(sys.argv[1]).resolve(strict=True)
binary = str(app / 'Contents/MacOS/Duckpad')


def processes():
    lines = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True).splitlines()
    return {int(parts[0]) for line in lines if len(parts := line.strip().split(None, 1)) == 2 and parts[1] == binary}


def script(source):
    return subprocess.run(['osascript', '-e', source], check=True, capture_output=True, text=True, timeout=8)


with tempfile.TemporaryDirectory(prefix='duckpad-terminal-shutdown-') as temporary:
    root = Path(temporary)
    marker = root / 'ready'
    namespace = 'terminal-shutdown-' + uuid.uuid4().hex
    before = processes()
    subprocess.run(['open', '-n', str(app), '--env', 'DUCKPAD_SECURITY_SCOPE_SMOKE_NAMESPACE=' + namespace,
                    '--stdout', str(root / 'stdout.log'), '--stderr', str(root / 'stderr.log')], check=True)
    pid = None
    try:
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            created = processes() - before
            if len(created) == 1:
                pid = created.pop()
                break
            time.sleep(.1)
        assert pid is not None, 'isolated app did not launch'
        time.sleep(1)
        script(f'''tell application "System Events" to tell (first process whose unix id is {pid})
            set frontmost to true
            click menu item "Terminal" of menu 1 of menu bar item "View" of menu bar 1
        end tell''')
        time.sleep(1)
        command = "printf ready > " + shlex.quote(str(marker)) + "; exec /usr/bin/yes DUCKPAD_SHUTDOWN_CHECK"
        script(f'''tell application "System Events" to tell (first process whose unix id is {pid})
            set frontmost to true
            if description of (value of attribute "AXFocusedUIElement") is not "Terminal" then error "Terminal not focused"
            keystroke {json.dumps(command)}
            key code 36
        end tell''')
        deadline = time.monotonic() + 10
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.1)
        assert marker.exists(), 'shell did not execute the test command'
        time.sleep(.75)
        start = time.monotonic()
        subprocess.run(['osascript', '-l', 'JavaScript', '-e', f'ObjC.import("AppKit"); $.NSRunningApplication.runningApplicationWithProcessIdentifier({pid}).terminate'],
                       check=True, capture_output=True, timeout=8)
        script(f'''tell application "System Events"
            if exists (first process whose unix id is {pid}) then
                tell (first process whose unix id is {pid})
                    set frontmost to true
                    repeat with w in windows
                        if exists static text "Close terminal sessions?" of w then click button "Close" of w
                    end repeat
                end tell
            end if
        end tell''')
        while pid in processes() and time.monotonic() - start < 5:
            time.sleep(.05)
        assert pid not in processes(), 'continuous-output shutdown exceeded five seconds'
        print(f'PASS: packaged Ghostty noisy-shell shutdown completed in {time.monotonic() - start:.3f}s')
    finally:
        if pid is not None and pid in processes():
            os.kill(pid, signal.SIGKILL)
