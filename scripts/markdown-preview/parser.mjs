import MarkdownIt from 'markdown-it';
import katexPlugin from '@vscode/markdown-it-katex';
import hljs from 'highlight.js';

export const markdown = new MarkdownIt({
  html: true, linkify: true,
  highlight(code, language) {
    if (language && hljs.getLanguage(language)) {
      try { return hljs.highlight(code, { language, ignoreIllegals: true }).value; } catch {}
    }
    return '';
  }
}).use(katexPlugin.default ?? katexPlugin, { throwOnError: false, trust: false, enableFencedBlocks: true });
// Local images are routed through the native file loader; never navigate to file URLs.
const validateLink = markdown.validateLink;
markdown.validateLink = url => /^file:/i.test(url) || validateLink(url);
const fence = markdown.renderer.rules.fence;
markdown.renderer.rules.fence = (tokens, index, options, env, self) => {
  if (tokens[index].info.trim() === 'mermaid') {
    return `<pre class="mermaid">${markdown.utils.escapeHtml(tokens[index].content)}</pre>`;
  }
  return fence(tokens, index, options, env, self);
};
