import { build } from 'esbuild';
import { cp, mkdir, readFile, writeFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = path.dirname(fileURLToPath(import.meta.url));
const output = path.resolve(root, '../../Sources/DuckpadPresentation/Resources/MarkdownPreview');
await mkdir(output, { recursive: true });
await build({ entryPoints: [path.join(root, 'clipboard.mjs')], bundle: true, format: 'iife', target: 'safari16', minify: true,
  outfile: path.join(output, 'clipboard.js'), legalComments: 'eof' });
await build({ entryPoints: [path.join(root, 'preview.mjs')], bundle: true, format: 'iife', target: 'safari16', minify: true,
  outfile: path.join(output, 'preview.js'), legalComments: 'eof' });
await cp(path.join(root, 'node_modules/katex/dist/fonts'), path.join(output, 'fonts'), { recursive: true });
await cp(path.join(root, 'node_modules/katex/dist/katex.min.css'), path.join(output, 'katex.css'));
await cp(path.join(root, 'node_modules/highlight.js/styles/github.css'), path.join(output, 'highlight.css'));
const notices = [];
async function collect(dir) {
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    if (!entry.isDirectory() || entry.name === '.bin') continue;
    const packageDir = path.join(dir, entry.name);
    if (entry.name.startsWith('@')) { await collect(packageDir); continue; }
    const files = await readdir(packageDir);
    for (const name of files.filter(name => /^(licen[sc]e|copying|notice)(\.|$)/i.test(name))) {
      try { notices.push(`\n=== ${path.relative(root, packageDir)}/${name} ===\n${await readFile(path.join(packageDir, name), 'utf8')}`); } catch {}
    }
    if (files.includes('node_modules')) await collect(path.join(packageDir, 'node_modules'));
  }
}
await collect(path.join(root, 'node_modules'));
await writeFile(path.join(output, 'THIRD_PARTY_NOTICES.txt'), notices.join('\n'));
