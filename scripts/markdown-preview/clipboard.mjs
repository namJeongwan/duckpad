import MarkdownIt from 'markdown-it';

// Clipboard HTML must stand alone: no scripts, raw HTML, stylesheet dependency,
// local file URLs or automatic resource loading by the receiving application.
const markdown = new MarkdownIt({ html: false, linkify: false, maxNesting: 32 });
markdown.validateLink = url => /^(https?:|mailto:)/i.test(url);
markdown.renderer.rules.image = (tokens, index) =>
  markdown.utils.escapeHtml(tokens[index].content || tokens[index].attrGet('src') || '');

const styles = {
  h1: 'font-size:16pt;margin:0 0 8pt;font-weight:bold',
  h2: 'font-size:14pt;margin:0 0 6pt;font-weight:bold',
  h3: 'font-size:12pt;margin:0 0 6pt;font-weight:bold',
  h4: 'font-size:11pt;margin:0 0 6pt;font-weight:bold',
  h5: 'font-size:11pt;margin:0 0 6pt;font-weight:bold',
  h6: 'font-size:11pt;margin:0 0 6pt;font-weight:bold',
  p: 'margin:0 0 6pt',
  ul: 'margin:0 0 6pt;padding-left:24pt',
  ol: 'margin:0 0 6pt;padding-left:24pt',
  li: 'margin:0',
  blockquote: 'margin:0 0 6pt;padding-left:12pt;border-left:3px solid #cccccc',
  table: 'border-collapse:collapse;margin:0 0 6pt',
  th: 'border:1px solid #cccccc;padding:4pt 8pt;font-weight:bold',
  td: 'border:1px solid #cccccc;padding:4pt 8pt',
  a: 'color:#0065b3;text-decoration:underline',
};
markdown.core.ruler.push('clipboard_styles', state => {
  const visit = tokens => {
    for (const token of tokens) {
      if (token.nesting === 1 && styles[token.tag]) token.attrJoin('style', styles[token.tag]);
      if (token.children) visit(token.children);
    }
  };
  visit(state.tokens);
});
const escape = markdown.utils.escapeHtml;
markdown.renderer.rules.code_inline = (tokens, index) =>
  `<code style="font-family:monospace;background-color:#f4f4f4">${escape(tokens[index].content)}</code>`;
const codeBlock = (tokens, index) =>
  `<pre style="margin:0 0 6pt;white-space:pre-wrap;font-family:monospace"><code>${escape(tokens[index].content)}</code></pre>\n`;
markdown.renderer.rules.fence = codeBlock;
markdown.renderer.rules.code_block = codeBlock;

export function clipboardHTML(source) {
  return '<html><head><meta charset="utf-8"></head><body><!--StartFragment-->' +
    '<div style="font-family:Arial,sans-serif;font-size:11pt;line-height:1.4;color:#202020">' +
    markdown.render(source) + '</div><!--EndFragment--></body></html>';
}
globalThis.duckpadClipboardHTML = clipboardHTML;
