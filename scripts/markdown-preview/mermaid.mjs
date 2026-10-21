import './compatibility.mjs';
import mermaid from 'mermaid';

mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', htmlLabels: false,
  theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
  maxTextSize: Number.MAX_SAFE_INTEGER, maxEdges: Number.MAX_SAFE_INTEGER,
  secure: ['secure', 'securityLevel', 'startOnLoad', 'htmlLabels', 'maxTextSize', 'maxEdges', 'suppressErrorRendering'],
  suppressErrorRendering: true });
window.duckpadMermaid = mermaid;
