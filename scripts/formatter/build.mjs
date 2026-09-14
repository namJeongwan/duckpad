import { build } from "esbuild";
import { mkdir, cp, readFile, writeFile, readdir } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { resolve, join } from "node:path";
import { createHash } from "node:crypto";

const root = fileURLToPath(new URL("../../", import.meta.url));
const output = resolve(root, "Sources/DuckpadInfrastructure/Resources/Formatter");
await mkdir(join(output, "licenses"), { recursive: true });
for (const [entry, filename] of [["entry.mjs", "formatter.js"], ["entry-json.mjs", "formatter-json.js"]]) {
  await build({
    absWorkingDir: fileURLToPath(new URL(".", import.meta.url)),
    entryPoints: [entry],
    outfile: join(output, filename),
    bundle: true, minify: true, format: "iife", platform: "browser",
    target: "safari16", legalComments: "eof",
  });
}
const lock = JSON.parse(await readFile(new URL("package-lock.json", import.meta.url), "utf8"));
const packages = [];
for (const [path, metadata] of Object.entries(lock.packages)) {
  if (!path || metadata.dev || metadata.optional) continue;
  const folder = fileURLToPath(new URL(`${path}/`, import.meta.url));
  const pkg = JSON.parse(await readFile(join(folder, "package.json"), "utf8"));
  const licenseFiles = (await readdir(folder)).filter(name => /^(licen[sc]e|copying|notice)/i.test(name));
  if (pkg.name === "railroad-diagrams") licenseFiles.push("README.md"); // CC0 declaration
  if (!licenseFiles.length) throw new Error(`Missing license: ${pkg.name}`);
  for (const name of licenseFiles) {
    await cp(join(folder, name), join(output, "licenses", `${pkg.name.replaceAll("/", "-")}-${name}`), { recursive: true });
  }
  packages.push({ name: pkg.name, version: pkg.version, license: pkg.license, integrity: metadata.integrity });
}
const bytes = await readFile(join(output, "formatter.js"));
const jsonBytes = await readFile(join(output, "formatter-json.js"));
await writeFile(join(output, "manifest.json"), JSON.stringify({
  sha256: createHash("sha256").update(bytes).digest("hex"),
  jsonSha256: createHash("sha256").update(jsonBytes).digest("hex"), packages,
}, null, 2) + "\n");
