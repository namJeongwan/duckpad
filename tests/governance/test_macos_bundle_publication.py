import importlib.util
import os
import pathlib
import stat
import tempfile
import unittest
from types import SimpleNamespace


ROOT = pathlib.Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "macos_bundle_publish", ROOT / "scripts" / "macos_bundle_publish.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class MacOSBundlePublicationTests(unittest.TestCase):
    def test_concurrent_output_appearance_never_nests_or_replaces(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = pathlib.Path(temporary).resolve()
            staging = parent / ".stage" / "Duckpad.app"
            output = parent / "Duckpad.app"
            staging.mkdir(parents=True)
            (staging / "marker").write_text("candidate", encoding="utf-8")
            output.mkdir()
            (output / "marker").write_text("concurrent", encoding="utf-8")

            with self.assertRaises(MODULE.PublicationError) as caught:
                MODULE.publish_bundle(str(staging), str(output))

            self.assertEqual(caught.exception.exit_code, 73)
            self.assertEqual((output / "marker").read_text(encoding="utf-8"), "concurrent")
            self.assertFalse((output / "Duckpad.app").exists())
            self.assertTrue(staging.exists())

    def test_cross_volume_identity_is_rejected_before_rename(self):
        directory_mode = stat.S_IFDIR | 0o700
        source = SimpleNamespace(st_mode=directory_mode, st_dev=11, st_ino=101)
        parent = SimpleNamespace(st_mode=directory_mode, st_dev=22, st_ino=202)
        renamed = False

        def fake_rename(_source, _destination):
            nonlocal renamed
            renamed = True

        with self.assertRaises(MODULE.PublicationError) as caught:
            MODULE.publish_bundle(
                "/resolved/.stage/Duckpad.app",
                "/resolved/Duckpad.app",
                lstat=lambda _path: source,
                stat=lambda _path: parent,
                lexists=lambda _path: False,
                realpath=lambda path: path,
                rename=fake_rename,
            )

        self.assertEqual(caught.exception.exit_code, 73)
        self.assertFalse(renamed)


if __name__ == "__main__":
    unittest.main()
