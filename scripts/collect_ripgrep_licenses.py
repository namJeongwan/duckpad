#!/usr/bin/env python3
"""Regenerate notices from cargo metadata for the pinned ripgrep source checkout.

Prepare metadata with cargo metadata --locked --format-version 1 --filter-platform
 aarch64-apple-darwin --manifest-path <pinned-source>/Cargo.toml. Normal app builds
use the checked-in notices and do not require Rust or Cargo.
"""
import argparse
import hashlib
import json
from pathlib import Path
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--metadata', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    manifest = json.loads((root / 'Vendor/Ripgrep/manifest.json').read_text())
    metadata = json.loads(args.metadata.read_text())
    output = args.output or root / 'Vendor/Ripgrep/NOTICES'
    (output / 'texts').mkdir(parents=True, exist_ok=True)
    workspace = Path(metadata['workspace_root'])
    packages = []

    def retain(data):
        digest = hashlib.sha256(data).hexdigest()
        (output / 'texts' / (digest + '.txt')).write_bytes(data)
        return digest

    def notices(directory):
        return [p for p in directory.iterdir() if p.is_file() and p.name.upper().startswith(
            ('LICENSE', 'LICENCE', 'COPYING', 'UNLICENSE', 'NOTICE', 'COPYRIGHT'))]

    for package in sorted(metadata['packages'], key=lambda p: (p['name'], p['version'])):
        directory = Path(package['manifest_path']).parent
        paths = notices(directory)
        if not paths and workspace in directory.parents:
            paths = notices(workspace)
        if package.get('license_file'):
            candidate = directory / package['license_file']
            if candidate.is_file() and candidate not in paths:
                paths.append(candidate)
        if not paths:
            raise RuntimeError('Missing notices for ' + package['name'])
        packages.append({'name': package['name'], 'version': package['version'], 'license': package.get('license'),
                         'notices': [{'name': p.name, 'sha256': retain(p.read_bytes())} for p in sorted(paths)]})
    pcre = manifest['pcre2_license']
    data = urllib.request.urlopen(pcre['url'], timeout=30).read()
    if hashlib.sha256(data).hexdigest() != pcre['sha256']:
        raise RuntimeError('PCRE2 license checksum mismatch')
    packages.append({'name': 'PCRE2', 'version': '10.45', 'license': 'BSD-3-Clause WITH PCRE2-exception',
                     'notices': [{'name': 'LICENCE.md', 'sha256': retain(data)}]})
    (output / 'index.json').write_text(json.dumps({'ripgrep_version': manifest['version'], 'packages': packages}, indent=2) + '\n')
    print('Retained notices for', len(packages), 'packages')


if __name__ == '__main__':
    main()
