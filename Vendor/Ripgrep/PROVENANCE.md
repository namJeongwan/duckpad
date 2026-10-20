# ripgrep 15.1.0

Duckpad bundles the unmodified official macOS release executables from
[BurntSushi/ripgrep 15.1.0](https://github.com/BurntSushi/ripgrep/releases/tag/15.1.0)
(source revision `af60c2de9d`). `manifest.json` pins each architecture archive and
its SHA-256. `scripts/build_ripgrep.py` verifies downloads, extracts only explicit
regular files, checks architecture/system library dependencies, and combines the
executables with `lipo` for universal packages. Packaging signs the helper with
the app identity, hardened runtime, and inherited App Sandbox entitlements.
Normal builds do not require a system rg, Rust, Cargo, or Homebrew.

The binaries report PCRE2 10.45. Duckpad uses rg for streaming, ignore-aware file discovery. All file contents,
Unicode folding, regex captures and replacement ranges are checked by Duckpad's
optimized native SearchEngine/ICU against immutable Data. The helper does not
read file contents or edit files. A prototype that copied verified bytes into
private files and relaunched rg for each batch regressed total search time; that
content-filter stage was removed before shipping. Selected-root `.gitignore` and
`.ignore` rules apply; global/parent ignore files and personal rg configuration do
not. Hidden files, symlinks and package directories remain excluded.

`NOTICES/index.json` maps package names and versions to deduplicated upstream
license/notice texts. It includes the complete locked Cargo metadata package set
(a superset of macOS-linked crates) and the PCRE2 license. The MIT, Unlicense,
Apache and other upstream notices are retained verbatim. Packaging copies these
to `Contents/Resources/ThirdPartyLicenses/Ripgrep`; verification checks each hash.

To regenerate notices, download the source archive in `manifest.json`, verify its
SHA-256, extract it into a temporary directory, then run:

```sh
cargo metadata --locked --format-version 1 --filter-platform aarch64-apple-darwin \
  --manifest-path <source>/Cargo.toml > <metadata.json>
python3 scripts/collect_ripgrep_licenses.py --metadata <metadata.json>
```

The generator retrieves PCRE2's pinned license URL and verifies its SHA-256.
Review generated notices together with any future binary/version update. No
upstream binary or source patches are maintained here.
