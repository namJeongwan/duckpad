import './compatibility.mjs';
import { markdown } from './parser.mjs';
import DOMPurify from 'dompurify';
let mermaidLoading;
let diagramsRunning = false;
let pendingDiagrams;
const diagramCache = new Map();
let cacheBytes = 0;
function loadMermaid() {
  if (window.duckpadMermaid) return Promise.resolve(window.duckpadMermaid);
  if (!mermaidLoading) mermaidLoading = new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = 'duckpad-preview://assets/mermaid.js';
    script.onload = () => resolve(window.duckpadMermaid);
    script.onerror = () => { mermaidLoading = undefined; script.remove(); reject(new Error('Diagram runtime unavailable')); };
    document.head.appendChild(script);
  });
  return mermaidLoading;
}

async function renderDiagrams(content, current, scroll) {
  const blocks = content.querySelectorAll('pre.mermaid');
  if (!blocks.length) return;
  try {
    const mermaid = await loadMermaid();
    for (const block of blocks) {
      if (version !== current || !block.isConnected) return;
      const source = block.textContent;
      try {
        const cached = diagramCache.get(source);
        // Reuse across renders, never duplicate one SVG's IDs within a page.
        let svg = cached?.generation !== current ? cached?.svg : undefined;
        if (!svg) {
          const result = await mermaid.render(`diagram-${current}-${Math.random().toString(36).slice(2)}`, source);
          if (version !== current || !block.isConnected) return;
          svg = DOMPurify.sanitize(result.svg, { USE_PROFILES: { svg: true, svgFilters: true, html: true } });
          // Bound both source and SVG retention; oversized diagrams still render.
          const bytes = (source.length + svg.length) * 2;
          if (bytes <= 4 * 1024 * 1024) {
            while (diagramCache.size && (diagramCache.size >= 16 || cacheBytes + bytes > 4 * 1024 * 1024)) {
              const [key, value] = diagramCache.entries().next().value;
              cacheBytes -= (key.length + value.svg.length) * 2; diagramCache.delete(key);
            }
            const previous = diagramCache.get(source);
            if (previous) cacheBytes -= (source.length + previous.svg.length) * 2;
            diagramCache.set(source, {svg, generation: current}); cacheBytes += bytes;
          }
        } else cached.generation = current;
        const diagram = document.createElement('div');
        diagram.className = 'mermaid-diagram'; diagram.innerHTML = svg;
        block.replaceWith(diagram);
      } catch { /* Keep invalid diagrams readable as source. */ }
    }
    if (version === current) window.scrollTo(0, scroll);
  } catch { /* Keep source visible if the optional bundled runtime fails to load. */ }
}

function discardPendingDiagrams() {
  pendingDiagrams?.resolve();
  pendingDiagrams = undefined;
}

function scheduleDiagrams(content, current, scroll) {
  discardPendingDiagrams();
  const completion = new Promise(resolve => { pendingDiagrams = {content, current, scroll, resolve}; });
  if (!diagramsRunning) {
    diagramsRunning = true;
    void (async () => {
      try {
        while (pendingDiagrams) {
          const request = pendingDiagrams;
          pendingDiagrams = undefined;
          try {
            if (version === request.current) await renderDiagrams(request.content, request.current, request.scroll);
          } finally { request.resolve(); }
        }
      } finally { diagramsRunning = false; }
    })();
  }
  return completion;
}
let version = 0;
let previousDocument;
window.duckpadRender = async (source, documentURL, plain = false, deferDiagrams = false) => {
  const current = ++version;
  discardPendingDiagrams();
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
  const diagrams = scheduleDiagrams(content, current, scroll);
  if (!deferDiagrams) await diagrams;
};
