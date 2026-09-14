import * as prettier from "prettier/standalone";
import babel from "prettier/plugins/babel";
import estree from "prettier/plugins/estree";

// JSON/JSONC/JSON5 use the same upstream parser and printer as the full bundle.
// Avoid loading unrelated language engines for the common JSON-only session.
globalThis.duckpadFormat = (text, options) => prettier.format(text, {
  parser: options.parser,
  tabWidth: options.tabWidth,
  useTabs: options.useTabs,
  printWidth: options.printWidth,
  singleQuote: options.singleQuote,
  semi: options.semi,
  endOfLine: "lf",
  plugins: [babel, estree],
});
