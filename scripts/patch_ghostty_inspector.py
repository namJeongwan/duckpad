#!/usr/bin/env python3
"""Localize the pinned Inspector's static UI text, never terminal/user data.

This reproducible patch uses a host-owned translation callback. UI arguments
are wrapped as complete expressions, including concatenated help sentences.
Internal ImGui IDs, printf-only formats and technical identifiers stay intact.
"""
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = Path(sys.argv[1])
MARKER = '// Duckpad inspector localization'
STR = r'"(?:[^"\\]|\\.)*"'
UI = re.compile(r'(?:cimgui\.c\.ImGui_(?:Begin|Button|Checkbox|CollapsingHeader|SelectableEx|SeparatorText|SetTooltip|TableHeader|TableSetupColumn(?:Ex)?|Text(?:Disabled|Wrapped|Unformatted|Colored)?|TreeNodeEx)|widgets\.helpMarker|self\.\w+_header\.(?:header|window))\(\s*')


def first_argument(text, start):
    """Find the first comma/closing paren outside strings and nested expressions."""
    i, depth = start, 0
    while i < len(text):
        if text[i] == '"':
            match = re.match(STR, text[i:])
            if not match:
                raise ValueError('Invalid pinned Zig string')
            i += len(match[0]); continue
        if text[i] in '([{': depth += 1
        elif text[i] in ')]}':
            if depth == 0: break
            depth -= 1
        elif text[i] == ',' and depth == 0: break
        i += 1
    return i


keys = set()
for path in sorted((SOURCE / 'src/inspector').rglob('*.zig')):
    if path.name == 'duckpad_i18n.zig': continue
    original = path.read_text()
    if MARKER in original:
        # Idempotency: reapply from the pinned original, not a partially patched file.
        import subprocess
        original = subprocess.check_output(['git', '-C', str(SOURCE), 'show', 'HEAD:' + str(path.relative_to(SOURCE))], text=True)
    changes = []
    for match in UI.finditer(original):
        start = match.end(); end = first_argument(original, start)
        if 'ImGui_TextColored(' in match[0]:
            start = end + 1
            while original[start].isspace(): start += 1
            end = first_argument(original, start)
        expression = original[start:end].rstrip()
        literals = re.findall(STR, expression)
        # Only complete static literals/concatenations. Runtime text stays untouched.
        remainder = re.sub(STR, '', expression).replace('++', '').strip()
        if not literals or remainder: continue
        value = ''.join(json.loads(s) for s in literals)
        visible = value.split('##')[0]
        if not re.search('[A-Za-z]', visible): continue
        # Formats which contain only units/coordinates are diagnostic identifiers.
        if '%' in value and not re.search(r'[A-Za-z]{3}', re.sub(r'%[-.*0-9]*[a-zA-Z]', '', visible)): continue
        keys.add(value)
        changes.append((start, start + len(expression), 'dp_i18n.text(' + expression + ')'))
    # Named dock windows must be translated consistently at creation and docking.
    if path.name in ('surface.zig', 'screen.zig'):
        for name, value in re.findall(r'const (window_\w+) = ("[^"]+");', original):
            if name == 'window_imgui_demo' or value == '"PageList"': continue
            keys.add(json.loads(value))
    for start, end, replacement in reversed(changes):
        original = original[:start] + replacement + original[end:]
    if path.name in ('surface.zig', 'screen.zig'):
        for name, value in re.findall(r'const (window_\w+) = ("[^"]+");', original):
            if name == 'window_imgui_demo' or value == '"PageList"': continue
            original = original.replace('const ' + name + ' = ' + value + ';', 'fn ' + name + '() [:0]const u8 { return dp_i18n.text(' + value + '); }')
            original = re.sub(r'\b' + name + r'\b(?!\()', name + '()', original)
        # The upstream ImGui demonstration is not terminal diagnostics and contains
        # an entire separate sample application. Do not expose it as shipping UI.
        original = original.replace('.show_demo_window = true,', '.show_demo_window = false,')
    if path.name == 'style.zig':
        keys.update(json.loads(value) for value in re.findall(r'\.\{ "\w+", (' + STR + r') \}', original))
    if path.name == 'widgets.zig':
        original = original.replace('ImGui_TextUnformatted(text.ptr)', 'ImGui_TextUnformatted(dp_i18n.text(text).ptr)')
    if path.name == 'termio.zig':
        for label in ['Pause##pause_play', 'Resume##pause_play']:
            keys.add(label)
            original = original.replace(json.dumps(label), 'dp_i18n.text(' + json.dumps(label) + ')')
    if path.name == 'key.zig':
        for label in ['Press: ', 'Release: ', 'Repeat: ', ' (composing)', '(invalid utf-8)']:
            keys.add(label)
            original = original.replace('writer.writeAll(' + json.dumps(label) + ')', 'writer.writeAll(dp_i18n.text(' + json.dumps(label) + '))')
    if path.name == 'page.zig':
        keys.update(['Page', 'Page %zu'])
        original = original.replace('std.fmt.bufPrintZ(\n            &label_buf,\n            "Page {d}",\n            .{state.index},\n        ) catch "Page"', 'dp_i18n.indexLabel(&label_buf, state.index)')
    if path.name == 'terminal.zig':
        keys.add('Screen: %s')
        original = original.replace('std.fmt.bufPrintZ(\n                &title_buf,\n                "Screen: {t}",\n                .{entry.key},\n            ) catch "Screen"', 'dp_i18n.screenLabel(&title_buf, @tagName(entry.key))')
    if changes or path.name == 'surface.zig':
        relative = '../duckpad_i18n.zig' if path.parent.name == 'widgets' else 'duckpad_i18n.zig'
        original = MARKER + '\nconst dp_i18n = @import("' + relative + '");\n' + original
        path.write_text(original)

# Dear ImGui's own table/docking menus use its built-in localization table.
# Enum order is pinned to dcimgui_internal.h from Ghostty's dcimgui dependency.
builtin_labels = [
    'Size column to fit###SizeOne', 'Size all columns to fit###SizeAll',
    'Size all columns to default###SizeAll', 'Reset order###ResetOrder',
    '(Main menu bar)', '(Popup)', '(Untitled)', "Open '%s'", 'Copy Link###CopyLink',
    'Hide tab bar###HideTabBar', 'Hold SHIFT to enable Docking window.',
    'Click and drag to move or undock whole node.',
]
keys.update(builtin_labels)

# Keep the reviewable, exact static key inventory alongside the patch.
inventory = ROOT / 'Vendor/Ghostty/inspector-localization-keys.json'
if '--write-inventory' in sys.argv:
    inventory.write_text(json.dumps(sorted(keys), ensure_ascii=False, indent=2) + '\n')
elif set(json.loads(inventory.read_text())) != keys:
    raise SystemExit('Pinned Inspector localization key inventory changed; review the patch')

bridge = r'''const std = @import("std");
pub const Callback = *const fn ([*:0]const u8) callconv(.c) ?[*:0]const u8;
var callback: ?Callback = null;
pub var font_path: [std.fs.max_path_bytes:0]u8 = @splat(0);

pub export fn duckpad_inspector_set_translation_callback(value: ?Callback, font: ?[*:0]const u8) void {
    callback = value;
    @memset(&font_path, 0);
    if (font) |path| {
        const bytes = std.mem.span(path);
        const count = @min(bytes.len, font_path.len - 1);
        @memcpy(font_path[0..count], bytes[0..count]);
    }
}

pub fn text(key: [:0]const u8) [:0]const u8 {
    const translate = callback orelse return key;
    const value = translate(key.ptr) orelse return key;
    return std.mem.span(value);
}

extern "c" fn snprintf(buffer: [*]u8, size: usize, format: [*:0]const u8, ...) c_int;
pub fn indexLabel(buffer: []u8, index: usize) [:0]const u8 {
    const len = snprintf(buffer.ptr, buffer.len, text("Page %zu").ptr, index);
    if (len < 0 or len >= buffer.len) return text("Page");
    return buffer[0..@intCast(len) :0];
}
pub fn screenLabel(buffer: []u8, name: [:0]const u8) [:0]const u8 {
    const len = snprintf(buffer.ptr, buffer.len, text("Screen: %s").ptr, name.ptr);
    if (len < 0 or len >= buffer.len) return text("Screen");
    return buffer[0..@intCast(len) :0];
}

const LocEntry = extern struct { key: c_int, value: [*:0]const u8 };
extern fn ImGui_LocalizeRegisterEntries(entries: [*]const LocEntry, count: c_int) void;
pub fn registerBuiltins() void {
    const entries = [_]LocEntry{
__BUILTIN_ENTRIES__
    };
    ImGui_LocalizeRegisterEntries(&entries, @intCast(entries.len));
}
'''
bridge = bridge.replace('__BUILTIN_ENTRIES__', '\n'.join('        .{ .key = %d, .value = text(%s).ptr },' % (i, json.dumps(label)) for i, label in enumerate(builtin_labels, 1)))
(SOURCE / 'src/inspector/duckpad_i18n.zig').write_text(bridge)
p = SOURCE / 'src/main_c.zig'; s = p.read_text()
line = 'comptime { _ = @import("inspector/duckpad_i18n.zig"); }'
if line not in s: p.write_text(s + '\n' + line + '\n')
p = SOURCE / 'include/ghostty.h'; s = p.read_text()
declaration = 'void duckpad_inspector_set_translation_callback(const char *(*translate)(const char *), const char *font_path);'
if declaration not in s:
    s = s.replace('void ghostty_inspector_set_focus(', declaration + '\nvoid ghostty_inspector_set_focus(')
    if declaration not in s: raise SystemExit('Pinned Inspector header anchor changed')
    p.write_text(s)
p = SOURCE / 'src/inspector/Inspector.zig'; s = p.read_text()
setup = 'pub fn setup() void {'
register = '\n    @import("duckpad_i18n.zig").registerBuiltins();'
if register not in s: s = s.replace(setup, setup + register)
anchor = '        const font_size = 16 * 2;'
font = '''
        // Dear ImGui 1.92 loads glyphs dynamically, including CJK translations.
        const localized_font = @import("duckpad_i18n.zig").font_path;
        if (localized_font[0] != 0) {
            if (cimgui.c.ImFontAtlas_AddFontFromFileTTF(io.Fonts, &localized_font, font_size, null, null) != null) return;
        }
'''
if font not in s: s = s.replace(anchor, anchor + font)
p.write_text(s)
print(f'Patched Inspector: {len(keys)} static localized text expressions')
