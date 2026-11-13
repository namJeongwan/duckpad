// Real pointer/keyboard input against the generated editor bundle. Requires the
// locally installed Chrome; uses an isolated profile and no user documents.
import assert from 'node:assert/strict';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {mkdir,mkdtemp,readFile,writeFile,rm} from 'node:fs/promises';
import {tmpdir} from 'node:os';
import {join} from 'node:path';
import {pathToFileURL,fileURLToPath} from 'node:url';
import {build} from 'esbuild';

const output=new URL('../../.build/markdown-editor-browser/',import.meta.url);
await mkdir(output,{recursive:true});
const assets=new URL('../../Sources/DuckpadEditorAdapter/Resources/MarkdownEditor/',import.meta.url);
const script=process.env.DUCKPAD_MARKDOWN_TEST_SCRIPT?pathToFileURL(process.env.DUCKPAD_MARKDOWN_TEST_SCRIPT):new URL('editor.js',assets);
const list=['1. 첫 번째 `started` 항목','2. 두 번째 `tenant` 항목','3. 세 번째 `opened` 항목','4. 네 번째 일반 텍스트 항목','5. 다섯 번째 `done` 항목'].join('\n');
const image='data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAX+XDSwAAAABJRU5ErkJggg==';
const cases=[
  ['table','| A | B |\n| --- | --- |\n| 한글 | `value` |\n| next | row |'],
  ['image',`![fixture](${image})`],
  ['rule','---'],
  ['code','```text\nfirst\nsecond\n```'],
  ['diagram','```mermaid\nflowchart LR\n A[Start]-->B[End]\n```'],
  ['mixed',`| A | B |\n| --- | --- |\n| 한글 | value |\n\n![fixture](${image})\n\n---\n\n\`\`\`text\nbody\n\`\`\``]
].map(([name,prefix])=>({name,text:'# Heading\n\n'+prefix+'\n\n## Numbered list\n\n'+list+'\n\nEnd'}));
const helper=`import {EditorView} from '@codemirror/view';window.testView=()=>EditorView.findFromDOM(document.querySelector('.cm-editor'));`;
await build({stdin:{contents:helper,resolveDir:fileURLToPath(new URL('.',import.meta.url))},bundle:true,format:'iife',target:'safari16',outfile:fileURLToPath(new URL('view.js',output))});
const html=`<!doctype html><html><head><meta charset="utf-8"><link rel="stylesheet" href="${new URL('editor.css',assets)}"><link rel="stylesheet" href="${new URL('katex.css',assets)}"></head><body><div id="editor"></div><script src="${new URL('mermaid.js',assets)}"></script><script src="${script}"></script><script src="view.js"></script><script>window.testCases=${JSON.stringify(cases)};</script></body></html>`;
await writeFile(new URL('index.html',output),html);
if(process.argv.includes('--prepare-only'))process.exit(0);
const profile=await mkdtemp(join(tmpdir(),'duckpad-editor-browser-'));
const chrome=spawn(process.env.CHROME_PATH??'/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',['--headless=new','--no-first-run','--no-default-browser-check','--disable-background-networking','--remote-debugging-port=0',`--user-data-dir=${profile}`,'about:blank'],{stdio:'ignore'});
const delay=ms=>new Promise(resolve=>setTimeout(resolve,ms));let socket;
try {
  let port;
  for(let i=0;i<100;i++){try{port=(await readFile(join(profile,'DevToolsActivePort'),'utf8')).split('\n')[0];break;}catch{await delay(50);}}
  assert(port,'Chrome did not start');
  const target=await(await fetch(`http://127.0.0.1:${port}/json/new?about:blank`,{method:'PUT'})).json();
  socket=new WebSocket(target.webSocketDebuggerUrl);await once(socket,'open');let sequence=0;const pending=new Map();
  socket.addEventListener('message',event=>{const message=JSON.parse(event.data),handler=pending.get(message.id);if(!handler)return;pending.delete(message.id);message.error?handler.reject(new Error(JSON.stringify(message.error))):handler.resolve(message.result);});
  function call(method,params={}) {
    return new Promise((resolve,reject)=>{
      const id=++sequence,timer=setTimeout(()=>{pending.delete(id);reject(new Error('Timeout: '+method));},15000);
      pending.set(id,{resolve:value=>{clearTimeout(timer);resolve(value);},reject:error=>{clearTimeout(timer);reject(error);}});socket.send(JSON.stringify({id,method,params}));
    });
  }
  async function evaluate(expression) {
    const result=await call('Runtime.evaluate',{expression,awaitPromise:true,returnByValue:true});
    assert(!result.exceptionDetails,JSON.stringify(result.exceptionDetails));return result.result.value;
  }
  async function key(name) {
    const code=name==='ArrowDown'?40:38;
    await call('Input.dispatchKeyEvent',{type:'keyDown',key:name,code:name,windowsVirtualKeyCode:code});
    await call('Input.dispatchKeyEvent',{type:'keyUp',key:name,code:name,windowsVirtualKeyCode:code});await delay(30);
  }
  await call('Page.navigate',{url:new URL('index.html',output).href});
  for(let i=0;i<100;i++){if(await evaluate(`!!window.DuckpadEditor&&!!window.testView`))break;await delay(50);}
  let checked=0;
  for(const width of [520,1200])for(const zoom of [0,5])for(let index=0;index<cases.length;index++) {
    const label=`${cases[index].name}, width=${width}, zoom=${zoom}`;
    await call('Emulation.setDeviceMetricsOverride',{width,height:1100,deviceScaleFactor:1,mobile:false});
    await evaluate(`DuckpadEditor.load({text:testCases[${index}].text,generation:1,editable:true,live:true,fontSize:16,zoom:${zoom},theme:'light',colors:{bg:'#fafafa',fg:'#202020',muted:'#656b78',border:'#dfdfe0',code:'#ebebec'},anchor:0,caret:0});true`);
    for(let i=0;i<100;i++){if(await evaluate(`document.querySelectorAll('.md-list').length===5&&[...document.querySelectorAll('img.md-image')].every(i=>i.complete&&i.naturalWidth>0)&&!document.querySelector('.md-diagram:not([data-state="ready"])')`))break;await delay(30);}
    assert(await evaluate(`!document.querySelector('.md-diagram:not([data-state="ready"])')`),`${label}: diagram did not render`);
    await evaluate(`document.querySelector('.md-list').scrollIntoView({block:'center'});testView().requestMeasure();true`);await delay(100);
    const first=cases[index].text.slice(0,cases[index].text.indexOf('1. 첫')).split('\n').length;
    await evaluate(`(()=>{const v=testView();v.dispatch({selection:{anchor:v.state.doc.line(${first}).from+3},scrollIntoView:true});v.focus();return true;})()`);await delay(50);
    await delay(100);
    const metrics=await evaluate(`(()=>{const v=testView();return [...document.querySelectorAll('.md-list')].map(e=>{const n=Number(e.textContent[0]),line=v.state.doc.line(${first}+n-1),r=e.getBoundingClientRect(),block=v.lineBlockAt(line.from);return {n,error:r.top-(v.documentTop+block.top)};});})()`);
    for(const row of metrics)assert(Math.abs(row.error)<1,`${label}: rendered row ${row.n} differs from height map by ${row.error}px`);
    for(let row=1;row<5;row++){await key('ArrowDown');assert.equal(await evaluate('testView().state.doc.lineAt(testView().state.selection.main.head).number'),first+row,`${label}: ArrowDown skips a row`);}
    for(let row=3;row>=0;row--){await key('ArrowUp');assert.equal(await evaluate('testView().state.doc.lineAt(testView().state.selection.main.head).number'),first+row,`${label}: ArrowUp skips a row`);}
    for(let row=0;row<5;row++) {
      const point=await evaluate(`(()=>{const e=document.querySelectorAll('.md-list')[${row}];e.scrollIntoView({block:'center'});const r=e.getBoundingClientRect();return {x:r.left+100,y:r.top+r.height/2};})()`);
      await call('Input.dispatchMouseEvent',{type:'mousePressed',...point,button:'left',clickCount:1});
      await call('Input.dispatchMouseEvent',{type:'mouseReleased',...point,button:'left',clickCount:1});await delay(70);
      assert.equal(await evaluate('testView().state.doc.lineAt(testView().state.selection.main.head).number'),first+row,`${label}: click lands on another row`);
    }
    assert.equal(await evaluate('DuckpadEditor.diagnostics().raw'),cases[index].text,`${label}: navigation changes source`);
    checked++;console.log('PASS',label);
  }
  console.log(`PASS: ${checked} real-browser block/list cases; height map, every click, Up/Down and unchanged source`);
} finally {
  socket?.close();chrome.kill('SIGTERM');if(chrome.exitCode===null)await once(chrome,'exit');await rm(profile,{recursive:true,force:true});
}
