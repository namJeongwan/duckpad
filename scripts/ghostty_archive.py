#!/usr/bin/env python3
"""Repack Zig archives through individual objects for Apple's stricter libtool."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile

args = sys.argv[1:]
assert args[:2] == ['-static', '-o'], args
output = str(Path(args[2]).resolve())
sources = [Path(p).resolve() for p in args[3:]]
with tempfile.TemporaryDirectory(prefix='duckpad-ghostty-archive-') as temporary:
    objects = []
    for index, source in enumerate(sources):
        directory = Path(temporary) / str(index)
        directory.mkdir()
        subprocess.run([os.environ['DUCKPAD_GHOSTTY_ZIG'], 'ar', 'x', str(source)], cwd=directory, check=True)
        for p in directory.iterdir():
            if p.is_file():
                p.chmod(0o600)
                objects.append(str(p))
    assert objects, 'No Ghostty objects'
    # A file list avoids ARG_MAX and preserves paths containing spaces.
    listing = Path(temporary) / 'objects.txt'
    listing.write_text('\n'.join(objects) + '\n')
    subprocess.run(['/usr/bin/libtool', '-static', '-o', output, '-filelist', str(listing)], check=True)
