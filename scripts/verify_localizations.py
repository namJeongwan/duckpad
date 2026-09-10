#!/usr/bin/env python3
"""Verify bundled UI catalogs without launching Duckpad or installing dependencies."""
import json
import plistlib
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources/DuckpadLocalization/Resources"
LANGUAGES = ("en", "ko", "ja", "zh-Hans", "pt-BR", "it", "fr", "de")
STRING = r'"(?:\\.|[^"\\])*"'
ENTRY = re.compile(rf'({STRING})\s*=\s*({STRING})\s*;')
FORMAT = re.compile(r'%(?:(\d+)\$)?(ld|lu|lld|llu|@|d|u|f)')


def read_strings(path):
    source = re.sub(r'/\*.*?\*/', '', path.read_text(), flags=re.S)
    result = {}
    for match in ENTRY.finditer(source):
        key, value = map(json.loads, match.groups())
        assert key not in result, f"{path}: duplicate key {key}"
        assert value, f"{path}: empty translation for {key}"
        result[key] = value
    assert not ENTRY.sub('', source).strip(), f"{path}: malformed .strings content"
    return result


def placeholders(value):
    return sorted(FORMAT.findall(value.replace('%%', '')))


def main():
    english = read_strings(RESOURCES / 'en.lproj/Localizable.strings')
    english_plurals = plistlib.loads((RESOURCES / 'en.lproj/Localizable.stringsdict').read_bytes())
    for locale in LANGUAGES:
        path = RESOURCES / f'{locale}.lproj'
        strings = read_strings(path / 'Localizable.strings')
        assert strings.keys() == english.keys(), f"{locale}: missing/extra translation keys"
        for key, source in english.items():
            assert placeholders(strings[key]) == placeholders(source), f"{locale}: incompatible format arguments: {key}"
        plurals = plistlib.loads((path / 'Localizable.stringsdict').read_bytes())
        assert plurals.keys() == english_plurals.keys(), f"{locale}: missing/extra plural keys"
        for key, entry in plurals.items():
            assert entry['NSStringLocalizedFormatKey'] == '%#@count@', f"{locale}: invalid plural format: {key}"
            rule = entry['count']
            assert rule['NSStringFormatSpecTypeKey'] == 'NSStringPluralRuleType'
            assert rule['NSStringFormatValueTypeKey'] == 'ld'
            for form in ('one', 'other'):
                assert placeholders(rule[form]) == [('', 'ld')], f"{locale}: bad plural argument: {key}/{form}"
    # Literal calls must resolve in the resource-owning target. Dynamic calls are
    # limited to stable menu/settings labels and covered by the AppKit tests.
    pattern = re.compile(rf'L10n\.text\(\s*({STRING})')
    for source in (ROOT / 'Sources').rglob('*.swift'):
        for match in pattern.finditer(source.read_text()):
            key = json.loads(match[1])
            assert key in english or key in english_plurals, f"{source}: uncataloged key {key}"
    print(f'PASS: {len(english)} strings and {len(english_plurals)} plural entries in all {len(LANGUAGES)} languages; format arguments and literal lookups verified.')


if __name__ == '__main__':
    main()
