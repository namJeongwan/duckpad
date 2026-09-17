# Duckpad website

A small Jekyll site with four pages in eight languages. The copy describes
Duckpad as a lightweight Notepad++ alternative for macOS. Headings stay at
26–28px, features use a list, and there are no animated entrances or promotional
hero sections. The sidebar uses the app icon alone; repeated taglines and the
extra tagline bar are removed. The large icon sits above the version link and
bold navigation, with a black arrow marking the active page. The Notepad++ inspiration note appears on About,
not in the shared footer. Existing screenshots and downloads are retained.

## Content and translations

- Shared layout: `_layouts/default.html`.
- Page contents: `_includes/pages/`.
- Strings: `_data/i18n/{en,ko,ja,zh-Hans,de,fr,it,pt-BR}.json`.
- Language names and path prefixes: `_data/languages.json`.
- Navigation and page routes: `_data/pages.json`.
- Current download version and assets: `_data/release.yml`.

Every language has the same 72 string keys. `:version` and `:macos` are
placeholders; preserve them when editing translations. Menu labels, clipboard
feedback, image alternatives, page titles and descriptions are translated too.
Technical identifiers such as Duckpad, GitHub, Swift and SHA-256 are unchanged.
Linked repository documentation remains English and is labeled accordingly.

English lives at `/`, `/download/`, `/resources/`, `/author/`. Other languages
use prefixes such as `/ko/` and `/pt-BR/download/`. Switching languages opens
the equivalent page. The upper-right picker supports searching by language name
or code, arrow-key selection, Enter, and Escape. Search and empty-state text are
localized. Subsequent navigation stays in that language. Explicit
URLs determine the language; there are no browser-language redirects or cookies.
Navigation and language links work without JavaScript. Locale pages are rendered
at build time, including `html lang`, canonical URLs and `hreflang` alternates.
No client-side translation library or custom Jekyll plugin is used. This follows
[Jekyll's data-file support](https://jekyllrb.com/docs/datafiles/).

## Local preview

From the repository root, using Ruby with the existing Liquid dependency:

```sh
ruby duckpad-jekyll/render-preview.rb
python3 duckpad-jekyll/verify-site.py
python3 -m http.server 8767 --bind 127.0.0.1 --directory build/website-preview
```

Open `http://127.0.0.1:8767/duckpad/ko/` or `/duckpad/` for English.
The renderer also refreshes `duckpad-website.html`, the four English
`duckpad-site-*.html` files and their localized counterparts. These standalone
files work directly from disk and use `duckpad-site-assets/`.

The preview renderer checks Liquid strictly but is not Jekyll itself. To build
with Jekyll:

```sh
jekyll build --source duckpad-jekyll --destination build/website-jekyll/duckpad
python3 duckpad-jekyll/verify-site.py build/website-jekyll/duckpad
```

`verify-site.py` checks key/placeholder parity, metadata, all 32 routes, local
links and sitemap entries. With the preview server running, Node and locally
installed Chrome can exercise the browser checks without npm packages:

```sh
node duckpad-jekyll/test-browser.mjs
```

Optional `SITE_ORIGIN` and `CHROME_PATH` select another local server or Chrome
binary. Tests use a temporary browser profile and cover 1280px/320px layouts,
language search and switching on a deep page, Escape/menu focus, clipboard feedback and
navigation without JavaScript. Screenshots are saved in the OS temporary folder.

## GitHub Pages source

`duckpad-jekyll/` is the deployable source; generated standalone prototypes and
app sources are not part of it. The URL configuration remains
`https://namjeongwan.github.io/duckpad`. The `.github/workflows/pages.yml` workflow builds this folder with GitHub's
Jekyll action and checks all localized routes and links on pull requests. Pushes
to `main` that change the site or workflow deploy the verified output to Pages.
It can also be run manually from `main`. PR builds have read-only permissions;
only the deployment job receives Pages and OIDC write permissions.

The repository's Pages publishing source must be **GitHub Actions**. The
`github-pages` environment should permit deployments from `main` only. Generated
standalone previews are local review files and are not needed for deployment.

The sitemap lists all 32 language/page combinations. On a project site,
`/duckpad/robots.txt` is not the domain-root robots file; configure a root robots
file only if you control that domain root. For another base path or a custom
domain, update `_config.yml` and the verification URL expectations together.

Download data was checked against the GitHub v0.6.3 release. The website does not
change app behavior, app version, signing, release files or the plugin API.

## Google Search Console

Register the URL-prefix property `https://namjeongwan.github.io/duckpad/`.
Use the **HTML tag** verification method. The token in `_config.yml` is rendered
inside the shared `<head>` on every language/page combination. Keep the tag
published after verification so Google can continue checking ownership.

The original HTML-file method also remains available at
`/duckpad/googled90414a55ce3575a.html`; the file is copied without changes.

After this change is merged and deployed:

1. Confirm the verification meta tag is present in the homepage source at
   `https://namjeongwan.github.io/duckpad/`, then click **Verify** under **HTML tag**
   in Search Console.
2. Submit `https://namjeongwan.github.io/duckpad/sitemap.xml` in **Sitemaps**.
3. Use **URL inspection** to request indexing of the English and Korean homepages.

Each homepage includes localized `SoftwareApplication` JSON-LD with a shared
application ID, the macOS requirement, release/download details, and the project
repository. Existing titles, descriptions, canonical URLs, language alternates,
and visible page content are retained. No rating or review is invented; this
markup alone does not satisfy Google's software-app rich-result requirements.
Ownership verification and sitemap submission do not guarantee indexing,
ranking, or correction of AI-generated answers.

References: [ownership verification](https://support.google.com/webmasters/answer/9008080),
[requesting a crawl](https://developers.google.com/search/docs/crawling-indexing/ask-google-to-recrawl),
and [software-app structured data](https://developers.google.com/search/docs/appearance/structured-data/software-app).
