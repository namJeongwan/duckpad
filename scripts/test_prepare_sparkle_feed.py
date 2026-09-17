"""Reject wrong or unpublished release archives before invoking the signer."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import tempfile
import unittest
from unittest.mock import patch
import zipfile

spec = importlib.util.spec_from_file_location('feed', Path(__file__).with_name('prepare_sparkle_feed.py'))
feed = importlib.util.module_from_spec(spec)
spec.loader.exec_module(feed)


class FeedPreparationTests(unittest.TestCase):
    def test_rejects_unpublished_modified_or_other_app_archives_before_signing(self):
        config = plistlib.loads((feed.ROOT / 'Packaging/Info.plist').read_bytes())
        for failure in ['draft', 'prerelease', 'digest', 'url', 'bundle', 'key', 'framework']:
            with self.subTest(failure=failure), tempfile.TemporaryDirectory() as temp:
                archive = Path(temp) / 'Duckpad-0.7.0-universal.zip'
                info = dict(config, CFBundleShortVersionString='0.7.0', CFBundleVersion='44')
                if failure == 'bundle':
                    info['CFBundleIdentifier'] += '.test'
                if failure == 'key':
                    info['SUPublicEDKey'] = 'other-key'
                with zipfile.ZipFile(archive, 'w') as z:
                    z.writestr('Duckpad.app/Contents/Info.plist', plistlib.dumps(info))
                    if failure != 'framework':
                        z.writestr('Duckpad.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle', b'fixture')
                release = {'draft': failure == 'draft', 'prerelease': failure == 'prerelease', 'published_at': '2026-09-17T00:00:00Z', 'assets': [{
                    'name': archive.name, 'state': 'uploaded', 'size': archive.stat().st_size,
                    'digest': 'sha256:' + (hashlib.sha256(archive.read_bytes()).hexdigest() if failure != 'digest' else 'invalid'),
                    'browser_download_url': ('https://github.com/namJeongwan/duckpad/releases/download/v0.7.0/' if failure != 'url' else 'https://example.invalid/') + archive.name}]}
                with patch.object(feed.subprocess, 'check_output', side_effect=[json.dumps(release).encode(), config['SUPublicEDKey']]), patch.object(feed.subprocess, 'run') as signer:
                    with self.assertRaises(ValueError):
                        feed.prepare(archive)
                    signer.assert_not_called()


if __name__ == '__main__':
    unittest.main()
