# Bundled formatters

- Prettier 3.9.6: https://github.com/prettier/prettier (MIT).
- @prettier/plugin-xml 3.4.2: https://github.com/prettier/plugin-xml (MIT).
- sql-formatter 15.8.2: https://github.com/sql-formatter-org/sql-formatter (MIT).
- Build tool: esbuild 0.28.2; not needed on users' machines.

`formatter.js` and `formatter-json.js` are generated, not hand-edited. Exact package versions and npm
integrity hashes are in `scripts/formatter/package-lock.json`; `manifest.json`
records both generated bundles' SHA-256 and runtime dependency metadata.
The `licenses/` directory includes upstream and transitive notices and is
shipped in the app's Infrastructure resource bundle.

Regenerate from the repository root:

```sh
npm ci --prefix scripts/formatter --ignore-scripts --no-audit --no-fund
npm run build --prefix scripts/formatter
```

Duckpad's integration is `scripts/formatter/entry.mjs`: statically bundled
standalone parsers, explicit formatting options, conservative XML whitespace,
and SQL dialect selection. `entry-json.mjs` uses the same Prettier standalone,
Babel parser, and ESTree printer for JSON/JSONC/JSON5, without loading unrelated
language plugins. JSON sessions start with that smaller bundle; requesting
another language replaces it with the full bundle, which is then reused for
all languages. Only one runtime and one cached script are retained. Upstream
package sources are not modified.
Document contents are passed as values to WebKit's JavaScript API. No user
configuration scripts or external plugins execute, and no document text is
inserted into the web view's HTML. A non-persistent web view and a restrictive
Content Security Policy constrain formatter execution. The runtime is reused
for nearby requests and released after 30 seconds idle. No Node installation
or network request is required at runtime.
