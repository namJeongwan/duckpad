#!/usr/bin/env python3
"""Exercise smoke clipboard cleanup on a disposable named macOS pasteboard.

Loads only the standalone harness definitions, without launching Duckpad.
No Accessibility permission is needed and the user clipboard is never touched.
"""
import ast
import json
from pathlib import Path
import subprocess
import types
import uuid

path = Path(__file__).with_name('smoke_noisy_shutdown.py')
tree = ast.parse(path.read_text())
namespace = {}
exec(compile(ast.Module(body=[node for node in tree.body if isinstance(node, (ast.Import, ast.ImportFrom, ast.FunctionDef))], type_ignores=[]), str(path), 'exec'), namespace)
name = 'org.duckpad.test.' + uuid.uuid4().hex

def run(args, **kwargs):
    args = list(args)
    if args[:3] == ['osascript', '-l', 'JavaScript']:
        args[4] = args[4].replace('$.NSPasteboard.generalPasteboard', '$.NSPasteboard.pasteboardWithName($(' + json.dumps(name) + '))')
    return subprocess.run(args, **kwargs)

namespace['subprocess'] = types.SimpleNamespace(run=run)
clipboard = namespace['clipboard_script']
snapshot_source = next(node.value for node in ast.walk(tree) if isinstance(node, ast.Constant) and isinstance(node.value, str) and 'const snapshot = ' in node.value)
def read():
    return json.loads(clipboard(snapshot_source))['items']
def seed():
    clipboard('''
        const first = $.NSPasteboardItem.alloc.init;
        first.setStringForType($('clipboard fixture'), $.NSPasteboardTypeString);
        first.setStringForType($('<b>fixture</b>'), $('public.html'));
        const second = $.NSPasteboardItem.alloc.init;
        second.setDataForType($.NSData.alloc.initWithBase64EncodedStringOptions($('AAECA/8='), 0), $('org.duckpad.fixture'));
        const items = $.NSMutableArray.alloc.init;
        items.addObject(first); items.addObject(second);
        board.clearContents; board.writeObjects(items);
    ''')
def timeout(source):
    subprocess.run(['sleep', '1'], timeout=0.01)

try:
    seed()
    original = read()
    assert len(original) == 2 and len(original[0]) == 2
    namespace['script'] = lambda source: None
    namespace['paste_command'](0, 'test command')
    assert read() == original
    print('PASS: all clipboard items/types restored after success')

    namespace['script'] = timeout
    try:
        namespace['paste_command'](0, 'test command')
        raise AssertionError('expected TimeoutExpired')
    except subprocess.TimeoutExpired:
        pass
    assert read() == original
    print('PASS: all clipboard items/types restored after child timeout')

    def replacement(source):
        clipboard("board.clearContents; board.setStringForType($('new external clipboard'), $.NSPasteboardTypeString);")
        timeout(source)
    namespace['script'] = replacement
    try:
        namespace['paste_command'](0, 'test command')
        raise AssertionError('expected TimeoutExpired')
    except subprocess.TimeoutExpired:
        pass
    assert read() == [{'public.utf8-plain-text': 'bmV3IGV4dGVybmFsIGNsaXBib2FyZA=='}]
    print('PASS: newer clipboard preserved after child timeout')

    seed()
    def changed_before_prepare(source, payload=None):
        if 'Clipboard changed before paste' in source:
            clipboard("board.clearContents; board.setStringForType($('new external clipboard'), $.NSPasteboardTypeString);")
        return clipboard(source, payload)
    namespace['clipboard_script'] = changed_before_prepare
    try:
        namespace['paste_command'](0, 'test command')
        raise AssertionError('expected failed ownership check')
    except RuntimeError:
        pass
    assert read() == [{'public.utf8-plain-text': 'bmV3IGV4dGVybmFsIGNsaXBib2FyZA=='}]
    print('PASS: clipboard change between backup and prepare preserved')


    seed()
    def cleared_before_prepare(source, payload=None):
        if 'Clipboard changed before paste' in source:
            clipboard('board.clearContents;')
        return clipboard(source, payload)
    namespace['clipboard_script'] = cleared_before_prepare
    try:
        namespace['paste_command'](0, 'test command')
        raise AssertionError('expected failed ownership check')
    except RuntimeError:
        pass
    assert read() == []
    print('PASS: external clear-only clipboard preserved before prepare')

    seed()
    original = read()
    def failed_write(source, payload=None):
        if 'Clipboard changed before paste' in source:
            source = source.replace("if (!board.writeObjects($.NSArray.arrayWithObject(item)))", "if (true)")
        return clipboard(source, payload)
    namespace['clipboard_script'] = failed_write
    try:
        namespace['paste_command'](0, 'test command')
        raise AssertionError('expected failed write')
    except RuntimeError:
        pass
    assert read() == original
    print('PASS: clipboard restored when command write fails after clear')
finally:
    clipboard('board.releaseGlobally;')
