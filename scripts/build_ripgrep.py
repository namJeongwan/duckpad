#!/usr/bin/env python3
"""Fetch pinned upstream ripgrep binaries; produce a native or universal helper."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import urllib.request


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--architecture', choices=['native', 'universal'], default='universal')
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    manifest = json.loads((root / 'Vendor/Ripgrep/manifest.json').read_text())
    base = root / '.build/ripgrep' / manifest['version']
    arches = ['arm64', 'x86_64'] if args.architecture == 'universal' else [platform.machine()]
    for arch in arches:
        asset = manifest['assets'][arch]
        directory = base / arch
        archive = base / asset['archive']
        base.mkdir(parents=True, exist_ok=True)
        if not archive.exists() or hashlib.sha256(archive.read_bytes()).hexdigest() != asset['sha256']:
            url = 'https://github.com/BurntSushi/ripgrep/releases/download/' + manifest['version'] + '/' + asset['archive']
            with urllib.request.urlopen(url, timeout=60) as response:
                payload = response.read(32 * 1024 * 1024 + 1)
            if hashlib.sha256(payload).hexdigest() != asset['sha256']:
                raise RuntimeError('ripgrep archive checksum mismatch')
            temporary = archive.with_suffix('.download')
            temporary.write_bytes(payload)
            os.replace(temporary, archive)
        with tarfile.open(archive) as source:
            # Copy only explicit regular files, never archive-provided paths/symlinks.
            prefix = asset['archive'].removesuffix('.tar.gz') + '/'
            directory.mkdir(parents=True, exist_ok=True)
            for name in ['rg', 'COPYING', 'LICENSE-MIT', 'UNLICENSE']:
                member = source.getmember(prefix + name)
                if not member.isfile() or member.size > 32 * 1024 * 1024:
                    raise RuntimeError('Unexpected ripgrep archive member')
                (directory / name).write_bytes(source.extractfile(member).read())
        (directory / 'rg').chmod(0o755)
        actual = subprocess.check_output(['lipo', '-archs', directory / 'rg'], text=True).strip()
        if actual != arch:
            raise RuntimeError('Unexpected ripgrep architecture')
    destination = base / args.architecture
    destination.mkdir(parents=True, exist_ok=True)
    helper = destination / 'rg'
    if len(arches) == 2:
        subprocess.run(['lipo', '-create', *[str(base / arch / 'rg') for arch in arches], '-output', helper], check=True)
    else:
        shutil.copyfile(base / arches[0] / 'rg', helper)
    helper.chmod(0o755)
    dependencies = subprocess.check_output(['otool', '-L', helper], text=True)
    if any('/opt/' in line or '/usr/local/' in line for line in dependencies.splitlines()):
        raise RuntimeError('ripgrep depends on non-system libraries')
    version = subprocess.check_output([helper, '--version'], text=True)
    if not version.startswith('ripgrep ' + manifest['version']) or 'PCRE2' not in version:
        raise RuntimeError('Unexpected ripgrep version or missing PCRE2')
    print(helper)


if __name__ == '__main__':
    main()
