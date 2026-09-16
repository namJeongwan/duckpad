// macOS 13 starts with Safari 16. esbuild lowers syntax, not runtime APIs.
if (typeof URL.canParse !== 'function') {
  URL.canParse = (input, base) => {
    try { new URL(input, base); return true; } catch { return false; }
  };
}
