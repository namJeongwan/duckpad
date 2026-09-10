# App localization

Duckpad 0.3.0 introduces eight bundled interface languages: `en`, `ko`, `ja`, `zh-Hans`, `pt-BR`, `it`, `fr`, and `de`. Chinese support is Simplified Chinese; Portuguese support is Brazilian Portuguese.

Users select **Preferences → General → App Language**. The default follows macOS's preferred languages, with English as the fallback. A manual selection is saved in the version-1 settings archive. Old archives without `appLanguage`, and unknown language identifiers, decode as `system`. A successful language change takes effect on the next launch, allowing native panels and all document windows to stay consistent. Failed settings writes restore the previous selection. The app-scoped `AppleLanguages` preference is updated only after a saved language change, for AppKit's native panels on the next launch.

The programming-language menu is separate from the app-language preference. User documents, file names, code, syntax identifiers, and third-party extension names are not translated.

## Resources and boundaries

`DuckpadLocalization` owns the `.lproj/Localizable.strings` and `.stringsdict` resources. `LocalizationCatalog` resolves a requested language and uses Foundation formatting, including plural selection. `L10n` holds the process catalog, initialized after settings load and before constructing UI. The module loads `Bundle.module` during SwiftPM development and the copied resource bundle inside the packaged `.app` in distribution.

Presentation, App, and EditorAdapter consume the catalog. Domain stores only the stable `AppLanguage` identifiers; application use cases and persistence do not depend on localization. Typed failure messages are translated by Presentation. Technical data such as file paths and version numbers remain arguments rather than translation keys.

Menus are assembled before translation. AppKit's action-based identifiers, selectors, targets, key equivalents, and represented objects are preserved. Menu source labels are stored separately for English command-palette searches. Window command buttons and settings categories route through stable identifiers, not translated text.

## Updating translations

1. Add the English source key and complete translations to each of the eight `Localizable.strings` files. Existing English source keys remain stable when their displayed wording changes.
2. Use `L10n.text` in UI code; pass dynamic values as positional arguments. Never pass document content as a lookup key. Use `.stringsdict` with integer arguments for inflected counts, and whole templates instead of concatenated sentence fragments.
3. Run `python3 scripts/verify_localizations.py` to check missing or duplicate keys, malformed resources, and incompatible placeholders.
4. Run `swift test --filter LocalizationTests`. The tests cover old settings archives, language negotiation, plural forms, all eight menu languages, English and translated command searches, settings category IDs, and view layout.
5. Build a release `.app` with `scripts/build_macos_app.sh` and run `scripts/verify_macos_app.sh` against it. Packaging must include `Duckpad_DuckpadLocalization.bundle`; source-only tests cannot prove this. Run `scripts/smoke_localizations.sh /absolute/path/Duckpad.app` to exercise every catalog inside the signed app without opening user sessions or preferences.

To save test-window images without accessing user documents:

```sh
DUCKPAD_LOCALIZATION_SNAPSHOTS=/tmp/duckpad-localization-snapshots \
  swift test --filter LocalizationTests
```

Translations should also receive fluent-speaker review. Automated checks establish resource and behavior correctness, not linguistic quality.
