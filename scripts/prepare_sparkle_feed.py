#!/usr/bin/env python3
"""Generate a signed Sparkle appcast from an already-published, verified ZIP.

Usage: python3 scripts/prepare_sparkle_feed.py path/to/Duckpad-X.Y.Z-universal.zip
Only the public feed is written to the checkout; private keys stay in Keychain.
"""
import base64
import hashlib
import json
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import xml.etree.ElementTree as ET
import zipfile

ROOT = Path(__file__).resolve().parent.parent
TOOLS = ROOT / '.build/artifacts/sparkle/Sparkle/bin'
ACCOUNT = 'com.namjeongwan.duckpad'
REPO = 'namJeongwan/duckpad'
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}


def prepare(archive):
    match = re.fullmatch(r'Duckpad-(\d+\.\d+\.\d+)-universal.zip', archive.name)
    if not match:
        raise ValueError('Expected Duckpad-X.Y.Z-universal.zip')
    version = match[1]
    release = json.loads(subprocess.check_output(['gh', 'api', f'repos/{REPO}/releases/tags/v{version}']))
    if release['draft'] or release['prerelease'] or not release['published_at']:
        raise ValueError('Publish a stable release before generating its feed')
    expected_url = f'https://github.com/{REPO}/releases/download/v{version}/{archive.name}'
    asset = next(a for a in release['assets'] if a['name'] == archive.name)
    checksum = hashlib.sha256()
    with archive.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            checksum.update(chunk)
    digest = checksum.hexdigest()
    if (asset['state'] != 'uploaded' or asset['size'] != archive.stat().st_size
            or asset['digest'] != 'sha256:' + digest or asset['browser_download_url'] != expected_url):
        raise ValueError('Published asset does not match the local ZIP')
    config = plistlib.loads((ROOT / 'Packaging/Info.plist').read_bytes())
    public_key = subprocess.check_output([str(TOOLS / 'generate_keys'), '--account', ACCOUNT, '-p'], text=True).strip()
    with zipfile.ZipFile(archive) as z:
        info = plistlib.loads(z.read('Duckpad.app/Contents/Info.plist'))
        has_sparkle = 'Duckpad.app/Contents/Frameworks/Sparkle.framework/Versions/B/Sparkle' in z.namelist()
    if (not has_sparkle or info.get('CFBundleIdentifier') != config['CFBundleIdentifier']
            or info['CFBundleShortVersionString'] != version
            or info.get('SUPublicEDKey') != public_key or config['SUPublicEDKey'] != public_key
            or info.get('SUFeedURL') != config['SUFeedURL']):
        raise ValueError('Archive version, updater, feed URL, or signing identity does not match')
    with tempfile.TemporaryDirectory(prefix='duckpad-appcast-') as temp:
        staging = Path(temp)
        shutil.copy2(archive, staging / archive.name)
        (staging / archive.with_suffix('.md').name).write_text(release['body'] or '', encoding='utf-8')
        subprocess.run([str(TOOLS / 'generate_appcast'), '--account', ACCOUNT,
                        '--maximum-deltas', '0', '--embed-release-notes',
                        '--download-url-prefix', expected_url.rsplit('/', 1)[0] + '/',
                        str(staging)], check=True)
        feed = staging / 'appcast.xml'
        tree = ET.parse(feed)
        items = tree.findall('./channel/item')
        if len(items) != 1:
            raise ValueError('Expected exactly one generated release')
        item = items[0]
        enclosure = item.find('enclosure')
        assert item.findtext('sparkle:version', namespaces=NS) == info['CFBundleVersion']
        assert item.findtext('sparkle:shortVersionString', namespaces=NS) == version
        assert enclosure.get('url') == expected_url
        assert int(enclosure.get('length')) == archive.stat().st_size
        assert len(base64.b64decode(enclosure.get('{' + NS['sparkle'] + '}edSignature'), validate=True)) == 64
        destination = ROOT / 'duckpad-jekyll/appcast.xml'
        destination.write_bytes(feed.read_bytes())
        print(f'Prepared {destination}; review and publish via the website PR workflow.')


if __name__ == '__main__':
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    prepare(Path(sys.argv[1]).resolve(strict=True))
