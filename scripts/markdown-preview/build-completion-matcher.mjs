// Reuse CodeMirror's MIT-licensed matcher without bringing its editor into AppKit.
import {readFileSync, writeFileSync, mkdirSync, copyFileSync} from 'node:fs';
import {fileURLToPath} from 'node:url';
import {dirname, resolve} from 'node:path';
import {build} from 'esbuild';
const directory = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(directory, 'node_modules/@codemirror/autocomplete');
const source = readFileSync(resolve(packageRoot, 'dist/index.js'), 'utf8');
const start = source.indexOf('class FuzzyMatcher {');
const end = source.indexOf('class StrictMatcher {', start);
if (start < 0 || end < 0) throw new Error('Pinned CodeMirror matcher layout changed');
const destination = resolve(directory, '../../Sources/DuckpadInfrastructure/Resources/CompletionMatching');
mkdirSync(destination, {recursive: true});
await build({stdin: {contents: `import {codePointAt, codePointSize, fromCodePoint} from '@codemirror/state';\n${source.slice(start, end)}\nexport function matches(query, candidates, limit) { const matcher = new FuzzyMatcher(query); const results = []; for (let index = 0; index < candidates.length; index++) { const match = matcher.match(candidates[index]); if (match) results.push({index, score: match.score, ranges: match.matched.slice()}); } results.sort((a,b) => b.score-a.score || a.index-b.index); return results.slice(0,limit); }`, resolveDir: directory}, bundle: true, format: 'iife', globalName: 'DuckpadCompletionMatching', outfile: resolve(destination, 'matcher.js'), legalComments: 'inline'});
const output = resolve(destination, 'matcher.js');
writeFileSync(output, readFileSync(output, 'utf8').replace(/[ \t]+$/gm, ''));
copyFileSync(resolve(packageRoot, 'LICENSE'), resolve(destination, 'LICENSE'));
