import './compatibility.mjs';
import { markdown } from './parser.mjs';
import DOMPurify from 'dompurify';
import mermaid from 'mermaid';

mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', htmlLabels: false,
  theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
  maxTextSize: Number.MAX_SAFE_INTEGER, maxEdges: Number.MAX_SAFE_INTEGER,
  secure: ['secure', 'securityLevel', 'startOnLoad', 'htmlLabels', 'maxTextSize', 'maxEdges', 'suppressErrorRendering'],
  suppressErrorRendering: true });
let version = 0;
let previousDocument;
window.duckpadRender = async (source, documentURL, plain = false) => {
  const current = ++version;
  const scroll = previousDocument === documentURL ? window.scrollY : 0;
  previousDocument = documentURL;
  const content = document.getElementById('content');
  if (plain) { content.textContent = source; return; }
  content.innerHTML = DOMPurify.sanitize(markdown.render(source), {
    USE_PROFILES: { html: true, mathMl: true, svg: true },
    ADD_TAGS: ['annotation'], ADD_ATTR: ['encoding'],
    FORBID_TAGS: ['style', 'iframe', 'object', 'embed', 'form', 'input', 'button'],
    ALLOW_UNKNOWN_PROTOCOLS: false,
    // file: is only retained on images, then rewritten before attaching a src.
    ALLOWED_URI_REGEXP: /^(?:(?:https?|mailto|file):|[^a-z]|[a-z+.-]+(?:[^a-z+.-:]|$))/i,
  });
  for (const link of content.querySelectorAll('a')) {
    const href = link.getAttribute('href') || '';
    if (!/^(https?:|mailto:|#)/i.test(href)) link.removeAttribute('href');
  }
  for (const img of content.querySelectorAll('img')) {
    const raw = img.getAttribute('src');
    if (!raw) continue;
    try {
      const url = new URL(raw, documentURL || 'duckpad-preview://unsaved/');
      if (url.protocol === 'file:') {
        img.src = 'duckpad-preview://local/?url=' + encodeURIComponent(url.href);
      } else if (!['https:', 'http:', 'data:'].includes(url.protocol)) img.removeAttribute('src');
    } catch { img.removeAttribute('src'); }
  }
  window.scrollTo(0, scroll);
  for (const block of content.querySelectorAll('pre.mermaid')) {
    if (version !== current) return;
    try {
      const result = await mermaid.render(`diagram-${current}-${Math.random().toString(36).slice(2)}`, block.textContent);
      if (version !== current || !block.isConnected) return;
      const diagram = document.createElement('div');
      diagram.className = 'mermaid-diagram';
      diagram.innerHTML = DOMPurify.sanitize(result.svg, { USE_PROFILES: { svg: true, svgFilters: true, html: true } });
      block.replaceWith(diagram);
    } catch { /* Keep the original diagram source readable on syntax errors. */ }
  }
  window.scrollTo(0, scroll);
};
