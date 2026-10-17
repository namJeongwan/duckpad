#!/usr/bin/env python3
"""Retain notices from the exact downloaded Ghostty dependency sources."""
import os
from pathlib import Path
import re
import shutil
import sys

source, destination = map(Path, sys.argv[1:])
cache = Path(os.environ.get('ZIG_GLOBAL_CACHE_DIR', str(Path.home() / '.cache/zig'))) / 'p'
visited = set()
queue = [source]
while queue:
    directory = queue.pop()
    if directory in visited or not directory.is_dir():
        continue
    visited.add(directory)
    for manifest in directory.rglob('build.zig.zon'):
        if any(part in ('.zig-cache', 'zig-out', '.git') for part in manifest.relative_to(directory).parts):
            continue
        for digest in re.findall(r'\.hash\s*=\s*"([^"]+)"', manifest.read_text()):
            queue.append(cache / digest)
    for path in directory.rglob('*'):
        if not path.is_file() or path.is_symlink():
            continue
        relative = path.relative_to(directory)
        if any(part in ('.zig-cache', 'zig-out', '.git', 'macos') for part in relative.parts):
            continue
        name = path.name.upper()
        if not name.startswith(('LICENSE', 'COPYING', 'NOTICE', 'OFL', 'FTL')):
            # zlib's distribution license is in its README.
            if not (name == 'README' and (directory / 'zlib.h').exists()):
                continue
        target = destination / directory.name / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
assert list(destination.rglob('LICENSE*')), 'Missing Ghostty dependency licenses'
