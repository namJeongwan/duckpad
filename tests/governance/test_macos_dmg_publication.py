"""Check exact-path DMG publication without mounting images or opening Finder."""

import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class DMGPublicationTests(unittest.TestCase):
    def test_concurrent_output_directory_is_not_used_as_a_container(self):
        script = Path(__file__).resolve().parents[2] / "scripts/build_macos_dmg.sh"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Duckpad.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_text("test bundle")
            output = root / "Duckpad.dmg"
            binaries = root / "bin"
            binaries.mkdir()
            # Only publication is under test; replace signing, image creation,
            # and Finder calls with deterministic local filesystem operations.
            commands = {
                "codesign": "exit 0\n",
                "swift": 'touch "$3"\n',
                "osascript": 'printf settings > "$2/.DS_Store"\n',
                "hdiutil": '''case "$1" in
    create) for last; do :; done; touch "$last" ;;
    attach)
        while [ "$1" != "-mountpoint" ]; do shift; done
        mount="$2"
        ditto "$(dirname "$mount")/contents" "$mount"
        ;;
    convert) for last; do :; done; printf image > "$last" ;;
    verify) mkdir "$DMG_TEST_OUTPUT" ;;
esac
''',
            }
            for name, body in commands.items():
                command = binaries / name
                command.write_text("#!/bin/sh\nset -eu\n" + body)
                command.chmod(0o755)
            result = subprocess.run(
                ["bash", str(script), "--app", str(app), "--output", str(output)],
                env={**os.environ, "PATH": f"{binaries}:/usr/bin:/bin",
                     "DMG_TEST_OUTPUT": str(output)},
                capture_output=True, text=True,
            )
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertTrue(output.is_dir(), result.stderr)
            self.assertEqual(list(output.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
