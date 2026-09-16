import { test } from 'node:test';
import assert from 'node:assert/strict';
import { markdown } from './parser.mjs';
test('Rust fences preserve indentation and highlight code', () => {
  const html = markdown.render('```rust\nfn main() {\n    let n = 1;\n}\n```');
  assert.match(html, /language-rust/); assert.match(html, /hljs-keyword/); assert.match(html, /    /);
  assert.doesNotMatch(markdown.render("'''rust\nfn main() {}\n'''"), /<pre/);
});
test('math is parsed before Markdown emphasis and Mermaid keeps source', () => {
  assert.match(markdown.render('$x_1 + x_2$'), /class="katex"/);
  assert.match(markdown.render('$$\nx^2\n$$'), /katex-display/);
  assert.match(markdown.render('```mermaid\ngraph TD; A-->B\n```'), /class="mermaid"/);
});
test('documents above former limit render without truncation', () => {
  assert.match(markdown.render('# Large\n\n' + 'text '.repeat(500000) + '\n\n# End'), /<h1>End<\/h1>/);
});

test('Safari 16 URL.canParse fallback accepts only parseable URLs', async () => {
  const original = URL.canParse;
  try {
    URL.canParse = undefined;
    await import('./compatibility.mjs');
    assert.equal(URL.canParse('https://example.com'), true);
    assert.equal(URL.canParse('../image.png', 'https://example.com/docs/'), true);
    assert.equal(URL.canParse('../image.png'), false);
    assert.equal(URL.canParse('http://['), false);
  } finally { URL.canParse = original; }
});
