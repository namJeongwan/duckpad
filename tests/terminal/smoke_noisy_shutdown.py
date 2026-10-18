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


def clipboard_script(source, payload=None):
    # Pass clipboard data over stdin, never command-line arguments or log output.
    prefix = """ObjC.import('AppKit');
        const board = $.NSPasteboard.generalPasteboard;
        const input = JSON.parse(ObjC.unwrap($.NSString.alloc.initWithDataEncoding(
            $.NSFileHandle.fileHandleWithStandardInput.readDataToEndOfFile, $.NSUTF8StringEncoding)));
    """
    result = subprocess.run(['osascript', '-l', 'JavaScript', '-e', prefix + source],
                            input=json.dumps(payload), check=True, capture_output=True, text=True, timeout=8)
    return result.stdout.strip()


def paste_command(pid, command):
    # System Events keystroke translates through the active input method (e.g.
    # Korean). Keep the backup in Python so a timed-out UI automation child
    # cannot skip restoring the user's clipboard.
    snapshot = json.loads(clipboard_script('''
        const snapshot = {count: board.changeCount, items: []};
        const items = board.pasteboardItems;
        for (let i = 0; i < items.count; i++) {
            const item = items.objectAtIndex(i);
            const copy = {};
            const types = item.types;
            for (let j = 0; j < types.count; j++) {
                const type = types.objectAtIndex(j);
                const data = item.dataForType(type);
                if (data.isNil()) throw new Error('Cannot back up clipboard type');
                copy[ObjC.unwrap(type)] = ObjC.unwrap(data.base64EncodedStringWithOptions(0));
            }
            snapshot.items.push(copy);
        }
        if (board.changeCount !== snapshot.count) throw new Error('Clipboard changed during backup');
        JSON.stringify(snapshot);
    '''))
    token = uuid.uuid4().hex
    token_type = 'org.duckpad.smoke.clipboard-owner'
    cleared_count = None
    try:
        prepared = json.loads(clipboard_script('''
            const result = {clearedCount: null, error: null};
            try {
                if (board.changeCount !== input.count) throw new Error('Clipboard changed before paste');
                const item = $.NSPasteboardItem.alloc.init;
                item.setStringForType($(input.command), $.NSPasteboardTypeString);
                item.setStringForType($(input.token), $(input.type));
                result.clearedCount = Number(board.clearContents);
                if (!board.writeObjects($.NSArray.arrayWithObject(item))) throw new Error('Cannot prepare paste');
            } catch (error) {
                result.error = String(error);
            }
            JSON.stringify(result);
        ''', {'count': snapshot['count'], 'command': command, 'token': token, 'type': token_type}))
        cleared_count = prepared['clearedCount']
        if prepared['error']:
            raise RuntimeError(prepared['error'])
        script(f'''tell application "System Events" to tell (first process whose unix id is {pid})
            set frontmost to true
            click menu item "Paste" of menu 1 of menu bar item "Edit" of menu bar 1
            delay 0.5
        end tell''')
    finally:
        # A newer clipboard owned by another application must not be overwritten.
        clipboard_script('''
            const count = board.changeCount;
            const ownedEmpty = input.emptyCount !== null && Number(count) === input.emptyCount
                && Number(board.pasteboardItems.count) === 0;
            if (ownedEmpty || ObjC.unwrap(board.stringForType($(input.type))) === input.token) {
                const items = $.NSMutableArray.alloc.init;
                for (const saved of input.items) {
                    const item = $.NSPasteboardItem.alloc.init;
                    for (const type of Object.keys(saved)) {
                        const data = $.NSData.alloc.initWithBase64EncodedStringOptions($(saved[type]), 0);
                        item.setDataForType(data, $(type));
                    }
                    items.addObject(item);
                }
                if (board.changeCount === count) {
                    board.clearContents;
                    if (items.count > 0 && !board.writeObjects(items)) throw new Error('Cannot restore clipboard');
                }
            }
        ''', {'items': snapshot['items'], 'token': token, 'type': token_type,
              'emptyCount': cleared_count})


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
        end tell''')
        paste_command(pid, command)
        script(f'''tell application "System Events" to tell (first process whose unix id is {pid})
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
        try:
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
        except subprocess.CalledProcessError:
            # The process may finish exiting while AX inspects its windows.
            if pid in processes():
                raise
        while pid in processes() and time.monotonic() - start < 5:
            time.sleep(.05)
        elapsed = time.monotonic() - start
        assert pid not in processes(), 'continuous-output shutdown exceeded five seconds'
        assert elapsed <= 5, f'continuous-output shutdown took {elapsed:.3f}s, exceeding five seconds'
        print(f'PASS: packaged Ghostty noisy-shell shutdown completed in {elapsed:.3f}s')
    finally:
        if pid is not None and pid in processes():
            os.kill(pid, signal.SIGKILL)
