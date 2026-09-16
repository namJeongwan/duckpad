// Browser checks use the locally installed Chrome and Node's built-in CDP client.
import { spawn } from 'node:child_process';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { once } from 'node:events';
import assert from 'node:assert/strict';

const root = new URL('.', import.meta.url);
const languages = JSON.parse(await readFile(new URL('_data/languages.json', root)));
const pages = JSON.parse(await readFile(new URL('_data/pages.json', root)));
const base = process.env.SITE_ORIGIN ?? 'http://127.0.0.1:8767';
const profile = await mkdtemp(join(tmpdir(), 'duckpad-site-chrome-'));
const chrome = spawn(process.env.CHROME_PATH ?? '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', [
  '--headless=new', '--no-first-run', '--no-default-browser-check', '--disable-background-networking',
  '--remote-debugging-port=0', `--user-data-dir=${profile}`, 'about:blank'
], { stdio: 'ignore' });
let socket;
const delay = ms => new Promise(resolve => setTimeout(resolve, ms));
try {
  let port;
  for (let n = 0; n < 100; n++) {
    try { port = (await readFile(join(profile, 'DevToolsActivePort'), 'utf8')).split('\n')[0]; break; } catch { await delay(100); }
  }
  assert(port, 'Chrome did not start');
  const target = await (await fetch(`http://127.0.0.1:${port}/json/new?about:blank`, { method: 'PUT' })).json();
  socket = new WebSocket(target.webSocketDebuggerUrl);
  await once(socket, 'open');
  let sequence = 0;
  const pending = new Map();
  socket.addEventListener('message', event => {
    const message = JSON.parse(event.data);
    if (!message.id) return;
    const handler = pending.get(message.id);
    if (!handler) return;
    pending.delete(message.id);
    message.error ? handler.reject(new Error(JSON.stringify(message.error))) : handler.resolve(message.result);
  });
  function call(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = ++sequence;
      const timer = setTimeout(() => { pending.delete(id); reject(new Error(`Timeout: ${method}`)); }, 15000);
      pending.set(id, { resolve: value => { clearTimeout(timer); resolve(value); }, reject: error => { clearTimeout(timer); reject(error); } });
      socket.send(JSON.stringify({ id, method, params }));
    });
  }
  async function evaluate(expression) {
    const { result, exceptionDetails } = await call('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    assert(!exceptionDetails, JSON.stringify(exceptionDetails));
    return result.value;
  }
  await call('Page.enable');
  await call('Runtime.enable');
  async function navigate(path) {
    await call('Page.navigate', { url: base + path });
    for (let n = 0; n < 100; n++) {
      if (await evaluate(`location.pathname === ${JSON.stringify(path)} && document.readyState === 'complete'`)) return;
      await delay(50);
    }
    throw new Error(`Page did not load: ${path}`);
  }
  for (const width of [1280, 320]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: false });
    for (const language of languages) {
      for (const page of pages) {
        const path = '/duckpad' + language.prefix + page.route;
        await navigate(path);
        const state = await evaluate(`({ lang: document.documentElement.lang, headings: document.querySelectorAll('h1').length,
          fontSize: parseFloat(getComputedStyle(document.querySelector('h1')).fontSize),
          width: document.documentElement.scrollWidth, viewport: innerWidth,
          images: [...document.images].every(image => image.complete && image.naturalWidth > 0),
          alternateCount: document.querySelectorAll('link[hreflang]').length,
          nav: [...document.querySelectorAll('.site-nav a')].map(a => a.getAttribute('href')) })`);
        assert.equal(state.lang, language.code, path);
        assert.equal(state.headings, 1, path);
        assert(state.fontSize <= 28, `Oversized heading: ${path}`);
        assert(state.width <= state.viewport + 1, `Horizontal overflow at ${width}: ${path}`);
        assert(state.images, `Broken image: ${path}`);
        assert.equal(state.alternateCount, 9, path);
        assert.deepEqual(state.nav, pages.map(p => '/duckpad' + language.prefix + p.route));
        if (width === 320) {
          assert(await evaluate(`document.querySelector('.menu-button').click(); document.querySelector('.menu-button').textContent === document.querySelector('.menu-button').dataset.close`));
          await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
          assert(await evaluate(`document.querySelector('.menu-button').getAttribute('aria-expanded') === 'false' && document.activeElement === document.querySelector('.menu-button')`));
        }
      }
    }
  }
  // Use real localized links, including a deep page rather than home.
  await navigate('/duckpad/ko/download/');
  await evaluate(`document.querySelector('.language-picker').open = true; document.querySelector('.language-picker a[hreflang="de"]').click()`);
  for (let n = 0; n < 50; n++) {
    if (await evaluate(`location.pathname === '/duckpad/de/download/' && document.documentElement.lang === 'de' && document.readyState === 'complete'`)) break;
    await delay(50);
  }
  assert(await evaluate(`location.pathname === '/duckpad/de/download/' && document.documentElement.lang === 'de'`));
  // Search, keyboard selection, and dismissal work on both viewport sizes.
  for (const width of [1280, 320]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height: 900, deviceScaleFactor: 1, mobile: false });
    await navigate('/duckpad/ko/resources/');
    async function openPicker() {
      await evaluate(`document.querySelector('.language-picker summary').click()`);
      for (let n = 0; n < 50; n++) {
        if (await evaluate(`document.activeElement === document.querySelector('#language-search')`)) return;
        await delay(20);
      }
      throw new Error('Language search did not receive focus');
    }
    async function query(value) {
      await evaluate(`{ const field = document.querySelector('#language-search'); field.value = ${JSON.stringify(value)}; field.dispatchEvent(new Event('input', { bubbles: true })); }`);
    }
    const visibleLanguages = () => evaluate(`[...document.querySelectorAll('#language-options li:not([hidden]) a')].map(a => a.hreflang)`);
    await openPicker();
    assert(await evaluate(`document.querySelector('#language-search').placeholder === '언어 검색' && document.querySelector('.language-popover').getBoundingClientRect().right <= innerWidth`));
    await query('portugues');
    assert.deepEqual(await visibleLanguages(), ['pt-BR']);
    await query('PT-BR');
    assert.deepEqual(await visibleLanguages(), ['pt-BR']);
    await query('없는 언어');
    assert.deepEqual(await visibleLanguages(), []);
    assert(await evaluate(`!document.querySelector('.language-empty').hidden && !document.querySelector('#language-search').hasAttribute('aria-activedescendant')`));
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
    assert(await evaluate(`location.pathname === '/duckpad/ko/resources/'`));
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 });
    assert(await evaluate(`!document.querySelector('.language-picker').open && document.activeElement === document.querySelector('.language-picker summary')`));
    await openPicker();
    assert.equal((await visibleLanguages()).length, 8);
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowDown', code: 'ArrowDown', windowsVirtualKeyCode: 40 });
    assert(await evaluate(`document.querySelector('#language-search').getAttribute('aria-activedescendant') === 'language-option-ja'`));
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'ArrowUp', code: 'ArrowUp', windowsVirtualKeyCode: 38 });
    assert(await evaluate(`document.querySelector('#language-search').getAttribute('aria-activedescendant') === 'language-option-ko'`));
    await query('영어');
    assert.deepEqual(await visibleLanguages(), ['en']);
    await evaluate(`document.querySelector('#language-search').dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', isComposing: true, bubbles: true}))`);
    assert(await evaluate(`location.pathname === '/duckpad/ko/resources/'`));
    await call('Input.dispatchKeyEvent', { type: 'keyDown', key: 'Enter', code: 'Enter', windowsVirtualKeyCode: 13 });
    for (let n = 0; n < 50; n++) {
      if (await evaluate(`location.pathname === '/duckpad/resources/' && document.readyState === 'complete'`)) break;
      await delay(50);
    }
    assert(await evaluate(`location.pathname === '/duckpad/resources/' && document.documentElement.lang === 'en'`));
    await openPicker();
    await evaluate(`document.querySelector('h1').dispatchEvent(new PointerEvent('pointerdown', { bubbles: true }))`);
    assert(await evaluate(`!document.querySelector('.language-picker').open`));
  }
  // Copy status must be localized on both success and failure paths.
  await navigate('/duckpad/ko/resources/');
  for (const fail of [false, true]) {
    await evaluate(`Object.defineProperty(navigator, 'clipboard', { configurable: true, value: { writeText: async text => { ${fail ? 'throw new Error("denied")' : 'window.copiedText = text'}; } } }); document.querySelector('[data-copy]').click();`);
    await delay(30);
    assert(await evaluate(`document.querySelector('.copy-status').textContent === document.querySelector('[data-copy]').dataset.${fail ? 'failure' : 'success'}`));
    assert(await evaluate(`document.querySelector('[data-copy]').disabled === false`));
  }
  assert.equal(await evaluate('window.copiedText'), 'swift run DuckpadApp');
  // Without JavaScript, the navigation and language links remain available.
  await call('Emulation.setScriptExecutionDisabled', { value: true });
  await navigate('/duckpad/ja/');
  assert(await evaluate(`getComputedStyle(document.querySelector('.site-nav')).display !== 'none' && document.querySelector('.menu-button').hidden`));
  assert(await evaluate(`document.querySelector('#language-search').hidden && document.querySelectorAll('.language-picker a').length === 8`));
  await call('Emulation.setScriptExecutionDisabled', { value: false });
  for (const [language, width] of [['en', 1280], ['ko', 1280], ['de', 320]]) {
    await call('Emulation.setDeviceMetricsOverride', { width, height: 1000, deviceScaleFactor: 1, mobile: false });
    await navigate('/duckpad' + (language === 'en' ? '' : '/' + language) + '/');
    const shot = await call('Page.captureScreenshot', { format: 'png' });
    await writeFile(join(tmpdir(), `duckpad-site-${language}-${width}.png`), Buffer.from(shot.data, 'base64'));
  }
  await evaluate(`document.querySelector('.language-picker summary').click()`);
  await delay(100);
  const pickerShot = await call('Page.captureScreenshot', { format: 'png' });
  await writeFile(join(tmpdir(), 'duckpad-site-language-320.png'), Buffer.from(pickerShot.data, 'base64'));
  console.log('PASS: 32 routes at desktop/mobile sizes; searchable language selection, IME, menu keyboard handling, copy feedback, and no-JS navigation');
} finally {
  socket?.close();
  chrome.kill('SIGTERM');
  await once(chrome, 'exit');
  await rm(profile, { recursive: true, force: true, maxRetries: 5, retryDelay: 100 });
}
