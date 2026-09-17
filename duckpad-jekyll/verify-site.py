"""Check translated keys, placeholders, routes, metadata and local links."""
from pathlib import Path
from html.parser import HTMLParser
from urllib.parse import urlsplit, unquote
import json
import re
import sys
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent
OUTPUT = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else ROOT.parent / 'build/website-preview/duckpad'
LANGUAGES = json.loads((ROOT / '_data/languages.json').read_text())
PAGES = json.loads((ROOT / '_data/pages.json').read_text())
REFERENCE = json.loads((ROOT / '_data/i18n/en.json').read_text())

class Page(HTMLParser):
    def __init__(self, text):
        super().__init__()
        self.elements = []
        self.feed(text)
    def handle_starttag(self, tag, attrs):
        self.elements.append((tag, dict(attrs)))
    def attrs(self, tag):
        return [attrs for name, attrs in self.elements if name == tag]

for language in LANGUAGES:
    code = language['code']
    data = json.loads((ROOT / '_data/i18n' / (code + '.json')).read_text())
    assert data.keys() == REFERENCE.keys(), f'{code}: translation keys differ'
    for key, value in data.items():
        assert isinstance(value, str) and value.strip(), f'{code}: empty {key}'
        assert sorted(re.findall(r':(?:version|macos)', value)) == sorted(re.findall(r':(?:version|macos)', REFERENCE[key])), f'{code}: placeholders in {key}'
    for entry in PAGES:
        route = language['prefix'] + entry['route']
        text = (OUTPUT / route.lstrip('/') / 'index.html').read_text()
        assert '{{' not in text and '{%' not in text and ':macos' not in text and ':version' not in text
        page = Page(text)
        head = Page(text.split('</head>', 1)[0])
        verification_tags = [a.get('content') for a in head.attrs('meta') if a.get('name') == 'google-site-verification']
        assert verification_tags == ['scHa8p9uG9QT56IrMbCLuIoSUaDheDRTeyvqw-y_ULU'], f'{route}: missing or incorrect verification meta tag in head'
        assert page.attrs('html')[0]['lang'] == code
        assert len(page.attrs('h1')) == 1
        links = page.attrs('link')
        canonical = next(a['href'] for a in links if a.get('rel') == 'canonical')
        assert canonical == 'https://namjeongwan.github.io/duckpad' + route
        alternates = {a['hreflang']: a['href'] for a in links if a.get('rel') == 'alternate'}
        assert len(alternates) == len(LANGUAGES) + 1
        for other in LANGUAGES:
            assert alternates[other['code']] == 'https://namjeongwan.github.io/duckpad' + other['prefix'] + entry['route']
        structured = re.findall(r'<script type="application/ld\+json">(.*?)</script>', text, re.S)
        assert len(structured) == (1 if entry['key'] == 'home' else 0), f'{route}: structured data placement'
        if structured:
            app = json.loads(structured[0])
            assert app['@context'] == 'https://schema.org' and app['@type'] == 'SoftwareApplication'
            assert app['@id'] == 'https://namjeongwan.github.io/duckpad/#duckpad'
            assert app['name'] == 'Duckpad' and app['inLanguage'] == code
            assert app['url'] == canonical and app['description'] == data['home_description']
            assert app['sameAs'] == 'https://github.com/namJeongwan/duckpad'
            assert app['operatingSystem'].startswith('macOS ')
            download_page = Page((OUTPUT / language['prefix'].lstrip('/') / 'download/index.html').read_text())
            assert app['downloadUrl'] in [a.get('href') for a in download_page.attrs('a')]
            assert app['softwareVersion'] in app['downloadUrl']
            assert 'aggregateRating' not in app and 'review' not in app
        assert f'<title>{data[entry["key"] + "_title"].replace("&", "&amp;")}' in text
        for tag, attrs in page.elements:
            link = attrs.get('href') if tag == 'a' else attrs.get('src') if tag == 'img' else None
            if not link or not link.startswith('/duckpad/'):
                continue
            relative = unquote(urlsplit(link).path[len('/duckpad/'):])
            target = OUTPUT / relative
            if link.endswith('/'):
                target /= 'index.html'
            assert target.is_file(), f'{route}: broken link {link}'
        for attrs in page.attrs('img'):
            assert 'alt' in attrs
        assert not re.search(r'Your text editor|Make yourself at home|A little familiar|The essentials', text)

verification = 'googled90414a55ce3575a.html'
assert (OUTPUT / verification).read_bytes() == (ROOT / verification).read_bytes(), 'Google verification file changed during build'

sitemap = ET.parse(OUTPUT / 'sitemap.xml')
urls = [entry.text for entry in sitemap.findall('.//{http://www.sitemaps.org/schemas/sitemap/0.9}loc')]
assert len(urls) == len(set(urls)) == 32
assert set(urls) == {'https://namjeongwan.github.io/duckpad' + lang['prefix'] + p['route'] for lang in LANGUAGES for p in PAGES}
print(f'PASS: {len(REFERENCE)} keys × 8 languages; 32 routes, metadata, alternate links, local links, structured data, verification file and sitemap')

# Sparkle needs the raw XML at the stable URL in every deployed site.
feed = ET.parse(OUTPUT / 'appcast.xml').getroot()
assert feed.tag == 'rss' and feed.attrib.get('version') == '2.0'
assert feed.find('channel') is not None
for item in feed.findall('./channel/item'):
    enclosure = item.find('enclosure')
    assert enclosure is not None
    assert enclosure.attrib['url'].startswith('https://github.com/namJeongwan/duckpad/releases/download/v')
    assert enclosure.attrib.get('{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature')
print('PASS: Sparkle appcast is present and well formed')
