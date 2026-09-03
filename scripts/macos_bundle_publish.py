#!/usr/bin/env python3
"""Publish one prepared app bundle without replacement or cross-volume copies."""

from __future__ import annotations

import ctypes
import errno
import os
import stat as stat_module
import sys


class PublicationError(Exception):
    def __init__(self, exit_code: int, message: str) -> None:
        super().__init__(message)
        self.exit_code = exit_code


def rename_exclusive(source: str, destination: str) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    function = libc.renameatx_np
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    at_fdcwd = -2
    rename_excl = 0x00000004
    if function(
        at_fdcwd,
        os.fsencode(source),
        at_fdcwd,
        os.fsencode(destination),
        rename_excl,
    ) != 0:
        value = ctypes.get_errno()
        raise OSError(value, os.strerror(value), destination)


def publish_bundle(
    source: str,
    destination: str,
    *,
    lstat=os.lstat,
    stat=os.stat,
    lexists=os.path.lexists,
    realpath=os.path.realpath,
    rename=rename_exclusive,
) -> None:
    if not os.path.isabs(source) or not os.path.isabs(destination):
        raise PublicationError(64, "bundle publication paths must be absolute")
    destination_parent = realpath(os.path.dirname(destination))
    if destination_parent != os.path.dirname(destination):
        raise PublicationError(73, "bundle output parent is not the resolved directory")
    try:
        source_before = lstat(source)
        parent = stat(destination_parent)
    except OSError as error:
        raise PublicationError(73, f"bundle publication input unavailable: {error}") from error
    if not stat_module.S_ISDIR(source_before.st_mode) or stat_module.S_ISLNK(source_before.st_mode):
        raise PublicationError(73, "bundle staging source is not a real directory")
    if source_before.st_dev != parent.st_dev:
        raise PublicationError(73, "bundle staging and output are on different volumes")
    if lexists(destination):
        raise PublicationError(73, f"bundle output already exists: {destination}")
    try:
        rename(source, destination)
    except OSError as error:
        code = 73 if error.errno in (errno.EEXIST, errno.EXDEV) else 74
        raise PublicationError(code, f"exclusive bundle publication failed: {error}") from error
    try:
        destination_after = lstat(destination)
    except OSError as error:
        raise PublicationError(74, f"published bundle identity unavailable: {error}") from error
    if lexists(source) or (
        destination_after.st_dev,
        destination_after.st_ino,
    ) != (
        source_before.st_dev,
        source_before.st_ino,
    ):
        raise PublicationError(74, "published bundle inode identity mismatch")


def main(arguments: list[str]) -> int:
    if len(arguments) != 2:
        print("Usage: macos_bundle_publish.py /absolute/staged.app /absolute/output.app", file=sys.stderr)
        return 64
    try:
        publish_bundle(arguments[0], arguments[1])
    except PublicationError as error:
        print(error, file=sys.stderr)
        return error.exit_code
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
