#!/usr/bin/env python3
"""Exercise the SDK-copy section of the real build script with disposable SDKs."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
BUILD = (ROOT / 'scripts/build_ghostty.sh').read_text()
SDK_SETUP = BUILD[BUILD.index('SDK="'):BUILD.index('mkdir -p "$TOOLCHAIN/bin"')]


class GhosttySDKTests(unittest.TestCase):
    def test_sdk_alias_and_failed_copy_are_safe(self):
        for use_alias, stale_link in [(False, False), (True, False), (True, True)]:
            with self.subTest(alias=use_alias, stale_link=stale_link), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                sdk = root / 'Installed SDKs' / 'MacOSX.sdk'
                library = sdk / 'usr/lib'
                library.mkdir(parents=True)
                original = library / 'libSystem.B.tbd'
                original.write_text('installed SDK stub')
                original.chmod(0o444)
                (library / 'libSystem.tbd').symlink_to('libSystem.B.tbd')
                alias = sdk.parent / 'MacOSX27.0.sdk'
                alias.symlink_to(sdk.name)
                toolchain = root / 'toolchain'
                zig_stub = toolchain / 'zig-aarch64-macos-0.15.2/lib/libc/darwin/libSystem.tbd'
                zig_stub.parent.mkdir(parents=True)
                zig_stub.write_text('compatible Zig stub')
                destination = toolchain / 'MacOSX.sdk'
                if stale_link:
                    destination.symlink_to(destination.name)
                commands = root / 'commands'
                commands.mkdir()
                xcrun = commands / 'xcrun'
                xcrun.write_text('#!/bin/sh\nprintf "%s\\n" "$TEST_SDK"\n')
                xcrun.chmod(0o755)
                env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'],
                           TEST_SDK=str(alias if use_alias else sdk),
                           TOOLCHAIN=str(toolchain), ZIG_ARCH='aarch64')
                result = subprocess.run(['bash', '-eu', '-c', SDK_SETUP], env=env,
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertFalse(destination.is_symlink())
                self.assertEqual((destination / 'usr/lib/libSystem.tbd').read_text(), 'compatible Zig stub')
                self.assertEqual(original.read_text(), 'installed SDK stub')
                self.assertEqual(original.stat().st_mode & 0o777, 0o444)


if __name__ == '__main__':
    unittest.main()
