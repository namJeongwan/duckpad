import test from 'node:test';
import assert from 'node:assert/strict';
import {parser,GFM} from '@lezer/markdown';
import katex from 'katex';
import {mathSyntax} from './editor-math.mjs';
const grammar=parser.configure([GFM,mathSyntax]);
const nodes=source=>{const result=[];grammar.parse(source).iterate({enter(node){if(/^Math/.test(node.name))result.push([node.name,source.slice(node.from,node.to)]);}});return result;};
test('math syntax distinguishes inline, display, escaped dollars, currency and code',()=>{
  const result=nodes('Inline $x_1+x_2$.\n\n$$\n\\frac{a}{b}\n$$\n\n`$code$` and \\$escaped plus $5 and $10.\n\n```js\n$x$\n```');
  assert.deepEqual(result.filter(([name])=>name!=='MathMark'),[['MathInline','$x_1+x_2$'],['MathBlock','$$\n\\frac{a}{b}\n$$']]);
});
test('single-line and incomplete display math preserve exact syntax',()=>{
  assert.deepEqual(nodes('$$x^2$$').filter(([name])=>name!=='MathMark'),[['MathBlock','$$x^2$$']]);
  assert.deepEqual(nodes('$$\nx^2').filter(([name])=>name==='MathMark'),[['MathMark','$$']]);
});
test('KaTeX never trusts document commands and invalid input remains visible',()=>{
  const options={trust:false,throwOnError:false,maxExpand:1000,maxSize:20};
  assert.doesNotMatch(katex.renderToString('\\href{javascript:alert(1)}{x}',options),/<a\b|href=/);
  assert.match(katex.renderToString('\\frac{',options),/katex-error/);
});
