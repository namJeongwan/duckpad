import * as prettier from "prettier/standalone";
import babel from "prettier/plugins/babel";
import estree from "prettier/plugins/estree";
import typescript from "prettier/plugins/typescript";
import html from "prettier/plugins/html";
import postcss from "prettier/plugins/postcss";
import markdown from "prettier/plugins/markdown";
import yaml from "prettier/plugins/yaml";
import graphql from "prettier/plugins/graphql";
import flow from "prettier/plugins/flow";
import glimmer from "prettier/plugins/glimmer";
import xml from "@prettier/plugin-xml";
import { format as formatSQL } from "sql-formatter";

// Only bundled parsers execute. Document contents are always passed as data;
// no config files, dynamic imports, network requests, or project code are run.
globalThis.duckpadFormat = async function (text, options) {
  if (options.parser === "sql") {
    const result = formatSQL(text, {
      language: options.sqlDialect,
      tabWidth: options.tabWidth,
      useTabs: options.useTabs,
      expressionWidth: options.printWidth,
    });
    return result.replace(/\r\n|\r/g, "\n").replace(/\n*$/, "\n");
  }
  return prettier.format(text, {
    parser: options.parser,
    tabWidth: options.tabWidth,
    useTabs: options.useTabs,
    printWidth: options.printWidth,
    singleQuote: options.singleQuote,
    semi: options.semi,
    endOfLine: "lf",
    xmlWhitespaceSensitivity: "strict",
    plugins: [babel, estree, typescript, html, postcss, markdown, yaml, graphql, flow, glimmer, xml],
  });
};
