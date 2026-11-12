// Build the same pinned Mermaid runtime for a standalone native plugin.
import {build} from 'esbuild';
import {dirname, resolve} from 'node:path';
import {fileURLToPath} from 'node:url';
const root = dirname(fileURLToPath(import.meta.url));
if (process.argv.length !== 3) throw new Error('Usage: node build-diagram-runtime.mjs OUTPUT.js');
await build({entryPoints: [resolve(root, 'mermaid.mjs')], bundle: true, format: 'iife', target: 'safari16',
  minify: true, outfile: resolve(process.argv[2]), legalComments: 'eof'});
