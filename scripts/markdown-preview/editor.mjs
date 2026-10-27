import {ChangeSet, Compartment, EditorState, EditorSelection, Transaction} from '@codemirror/state';
import {EditorView, keymap, drawSelection, lineNumbers} from '@codemirror/view';
import {defaultKeymap, indentWithTab} from '@codemirror/commands';
import {markdown, markdownKeymap} from '@codemirror/lang-markdown';
import {languages} from '@codemirror/language-data';
import {HighlightStyle, syntaxHighlighting} from '@codemirror/language';
import {tags} from '@lezer/highlight';
import {GFM} from '@lezer/markdown';
import {RawDocument, normalized} from './editor-raw-document.mjs';
import {mathSyntax} from './editor-math.mjs';
import {liveExtensions, liveMode, setLive, setComposing, setDragging} from './editor-live.mjs';
import {commitTableInput,tableCommand,enterTableWithArrow} from './editor-table.mjs';
import {linkPresentation,linkMouseDown,linkClick} from './editor-link.mjs';

let view, raw, generation=0, composingBefore=null, pendingHost=[],desiredWrap=true,pointerEvents,selectionDragging=false,pointerRelease,editorFontSize=13,editorZoom=0;
function finishPointerSelection() {
  if(!selectionDragging)return;
  const current=view;
  clearTimeout(pointerRelease);
  pointerRelease=setTimeout(()=>{
    if(view!==current||!selectionDragging)return;
    selectionDragging=false;view.dispatch({effects:setDragging.of(false)});
  },50);
}
const highlighting=HighlightStyle.define([
  {tag:[tags.keyword,tags.modifier,tags.controlKeyword],color:'var(--syntax-keyword)'},
  {tag:tags.comment,color:'var(--syntax-comment)',fontStyle:'italic'},
  {tag:[tags.number,tags.bool,tags.null],color:'var(--syntax-number)'},
  {tag:[tags.string,tags.character,tags.regexp],color:'var(--syntax-string)'},
  {tag:[tags.operator,tags.punctuation],color:'var(--syntax-operation)'},
  {tag:[tags.link,tags.url],color:'var(--link)'},
  {tag:tags.heading,fontWeight:'bold'},
  {tag:tags.strong,fontWeight:'bold'},
  {tag:tags.emphasis,fontStyle:'italic'},
  {tag:tags.strikethrough,textDecoration:'line-through'},
  {tag:tags.invalid,color:'var(--error)'}
]);
const editable=new Compartment(), wrapping=new Compartment(), theme=new Compartment();
const external=Transaction.remote;
const host=message=>window.webkit?.messageHandlers.duckpadEditor.postMessage({...message,generation})??Promise.resolve({accepted:true});
window.DuckpadEditorHost=host;
const selection=()=>raw.selection(view.state.selection);
function selectionFromNative(config) {
  const ranges=config.ranges||[{anchor:config.anchor||0,caret:config.caret||0}];
  const positions=raw.positionsAtUTF8(ranges.flatMap(range=>[range.anchor,range.caret]));
  return EditorSelection.create(ranges.map(range=>EditorSelection.range(positions.get(range.anchor),positions.get(range.caret))),config.mainIndex||0);
}
function send(message) { void host(message).catch(()=>{}); }
function compositionFinished() {
  if(composingBefore===null)return;
  const before=composingBefore,after=raw.raw;composingBefore=null;
  let first=0,endBefore=before.length,endAfter=after.length;
  while(first<endBefore&&first<endAfter&&before[first]===after[first])first++;
  if(first>0&&/[\uD800-\uDBFF]/.test(before[first-1]))first--;
  while(endBefore>first&&endAfter>first&&before[endBefore-1]===after[endAfter-1]){endBefore--;endAfter--;}
  if(endBefore<before.length&&/[\uDC00-\uDFFF]/.test(before[endBefore])){endBefore++;endAfter++;}
  const encoder=new TextEncoder();
  if(before!==after)send({type:'edit',edits:[{location:encoder.encode(before.slice(0,first)).length,
    length:encoder.encode(before.slice(first,endBefore)).length,deleted:before.slice(first,endBefore),replacement:after.slice(first,endAfter)}],selection:selection()});
  send({type:'composition',active:false});
  view.dispatch({effects:setComposing.of(false)});
  if(pendingHost.length)applyHostEdits({edits:pendingHost.splice(0)});
}
function update(update) {
  if(!raw)return;
  for(const transaction of update.transactions) {
    if(transaction.docChanged&&!transaction.annotation(external)) {
      const message=raw.change(transaction.changes,transaction.state.selection);
      if(composingBefore===null)send({type:'edit',...message});
    }
  }
  if(update.selectionSet&&!update.docChanged&&composingBefore===null
     &&!update.startState.selection.eq(update.state.selection)
     &&update.transactions.some(transaction=>!transaction.annotation(external)))send({type:'selection',selection:selection()});
}
function applyHostEdit(edit) {
  applyHostEdits({edits:[edit]});
}
function applyHostEdits(payload) {
  if(!view)return;
  const edits=payload.edits.filter(edit=>edit.generation===generation);
  if(!edits.length)return;
  if(composingBefore!==null){pendingHost.push(...edits);return;}
  let changes=ChangeSet.empty(view.state.doc.length);
  for(const edit of edits) {
    const change=raw.nativeChange(edit.location,edit.length,edit.replacement);
    changes=changes.compose(ChangeSet.of(change,changes.newLength));
  }
  view.dispatch({changes,annotations:external.of(true)});
}
async function flush() {
  commitTableInput(view);
  // Native Save/Close commands must see every posted text transaction before
  // taking a synchronous snapshot. The reply is an ordered WebKit barrier.
  if(composingBefore!==null) {
    view.contentDOM.blur();
    await new Promise(resolve=>setTimeout(resolve,20));
    compositionFinished();
  }
  await host({type:'barrier'});return true;
}
const command=name=>{void flush().then(()=>host({type:'command',command:name}));return true;};
function load(config) {
  clearTimeout(pointerRelease);pointerEvents?.abort();pointerEvents=new AbortController();selectionDragging=false;
  for(const event of ['mouseup','blur','dragend'])window.addEventListener(event,finishPointerSelection,{signal:pointerEvents.signal});
  for(const event of ['keydown','keyup','mousemove','blur'])window.addEventListener(event,e=>document.body.classList.toggle('md-open-links',event!=='blur'&&e.metaKey),{signal:pointerEvents.signal});
  view?.destroy();generation=config.generation;
  raw=new RawDocument(config.text,config.lineEnding||'\n');
  composingBefore=null;pendingHost=[];
  window.DuckpadEditorLabels=config.labels||{};
  window.DuckpadEditorDocumentURL=config.documentURL;
  const state=EditorState.create({doc:normalized(config.text),selection:selectionFromNative(config),extensions:[
    EditorState.allowMultipleSelections.of(true),markdown({extensions:[GFM,mathSyntax],codeLanguages:languages}),
    syntaxHighlighting(highlighting),lineNumbers(),drawSelection(),
    keymap.of([{key:'Mod-z',run:()=>command('undo')},{key:'Mod-Shift-z',run:()=>command('redo')},
      {key:'Mod-s',run:()=>command('save')},...['ArrowLeft','ArrowRight','ArrowUp','ArrowDown'].map(key=>({key,run:view=>view.state.field(liveMode)&&enterTableWithArrow(view,key)})),...markdownKeymap,indentWithTab,...defaultKeymap]),
    linkPresentation,...liveExtensions,editable.of([EditorState.readOnly.of(!config.editable),EditorView.editable.of(!!config.editable)]),
    wrapping.of(EditorView.lineWrapping),theme.of(EditorView.theme({}, {dark:config.theme==='dark'||config.theme==='highContrastDark'})),
    EditorView.updateListener.of(update),EditorView.domEventHandlers({
      focus(){send({type:'focus'});},
      click:linkClick,
      mousedown(event){
        if(linkMouseDown(event))return true;
        if(event.button!==0||event.target.closest('.md-editable-table,.md-diagram'))return;
        clearTimeout(pointerRelease);selectionDragging=true;view.dispatch({effects:setDragging.of(true)});
      },
      compositionstart(event){if(event.target.closest('.md-editable-table'))return;composingBefore=raw.raw;send({type:'composition',active:true});view.dispatch({effects:setComposing.of(true)});},
      compositionend(){setTimeout(compositionFinished,0);},
      copy(event){if(event.target.closest('.md-editable-table'))return;const range=view.state.selection.main;if(range.empty)return;
        event.clipboardData.setData('text/plain',raw.raw.slice(raw.rawOffset(range.from),raw.rawOffset(range.to)));event.preventDefault();return true;}
    })
  ]});
  view=new EditorView({state,parent:document.getElementById('editor')});
  configure(config);return true;
}
function configure(config) {
  if(!view)return;
  const changedLive=config.live!==undefined&&config.live!==view.state.field(liveMode);
  if(changedLive||config.editable===false)commitTableInput(view);
  if(config.labels)window.DuckpadEditorLabels=config.labels;
  const changedDocumentURL=config.documentURL!==undefined&&config.documentURL!==window.DuckpadEditorDocumentURL;
  if(config.documentURL!==undefined)window.DuckpadEditorDocumentURL=config.documentURL;
  if(config.lineEnding)raw.lineEnding=config.lineEnding;
  const effects=[];
  if(changedLive)effects.push(setLive.of(config.live));
  else if(changedDocumentURL||config.labels)effects.push(setLive.of(view.state.field(liveMode)));
  if(config.editable!==undefined){
    if(!config.editable)compositionFinished();
    effects.push(editable.reconfigure([EditorState.readOnly.of(!config.editable),EditorView.editable.of(!!config.editable)]));
  }
  if(config.theme&&document.body.dataset.theme!==config.theme){
    document.body.dataset.theme=config.theme;
    document.documentElement.style.colorScheme=/dark/i.test(config.theme)?'dark':'light';
    effects.push(theme.reconfigure(EditorView.theme({}, {dark:/dark/i.test(config.theme)})),setLive.of(config.live??view.state.field(liveMode)));
  }
  if(config.colors) {
    window.DuckpadEditorColors=config.colors;
    for(const [key,value] of Object.entries(config.colors))if(/^#[0-9a-f]{6}$/i.test(value))document.documentElement.style.setProperty('--'+key,value);
    // Rebuild diagram widget identities so their SVG/cache follows this palette.
    effects.push(setLive.of(config.live??view.state.field(liveMode)));
  }
  if(config.wrap!==undefined)desiredWrap=config.wrap;
  if(config.wrap!==undefined||config.live!==undefined)effects.push(wrapping.reconfigure(desiredWrap||(config.live??view.state.field(liveMode))?EditorView.lineWrapping:[]));
  if(config.fontSize!==undefined)editorFontSize=config.fontSize;
  if(config.zoom!==undefined)editorZoom=config.zoom;
  if(config.fontSize!==undefined||config.zoom!==undefined){document.documentElement.style.setProperty('--source-size',Math.max(6,editorFontSize+editorZoom)+'px');document.documentElement.style.setProperty('--body-size',Math.max(6,Math.max(16,editorFontSize)+editorZoom)+'px');}
  if(config.fontName)document.documentElement.style.setProperty('--code-font',JSON.stringify(config.fontName)+',Menlo,monospace');
  if(effects.length)view.dispatch({effects});
  if(config.editable!==undefined)send({type:'admission',editable:!!config.editable});
}
function nativeSelection(config) {
  if(!view||composingBefore!==null)return;
  const selection=selectionFromNative(config),current=view.state.selection;
  // A status echo carries byte positions only. Keep CodeMirror's vertical goal
  // column and bidi affinity when those positions have not changed.
  if(config.scroll===false&&selection.mainIndex===current.mainIndex&&selection.ranges.length===current.ranges.length&&selection.ranges.every((range,index)=>range.anchor===current.ranges[index].anchor&&range.head===current.ranges[index].head))return;
  view.dispatch({selection,scrollIntoView:config.scroll!==false,annotations:external.of(true)});
}
window.DuckpadEditor={load,configure,applyHostEdit,applyHostEdits,nativeSelection,flush,focus:()=>view?.focus(),
  reloadImages(){for(const image of document.querySelectorAll('img.md-image')){if(image.src.startsWith('duckpad-editor:')){const url=new URL(image.src);url.searchParams.set('reload',String(Date.now()));image.src=url.href;}}},
  async nativeCommand(value){
    await flush();const command=typeof value==='string'?value:value.command;
    if(!await tableCommand(view,command))await host({type:'command',command});
  },
  diagnostics(){return {raw:raw.raw,text:view.state.doc.toString(),live:view.state.field(liveMode),generation,
    composing:composingBefore!==null,head:view.state.selection.main.head,goalColumn:view.state.selection.main.goalColumn,
    headings:[...document.querySelectorAll('.md-h1,.md-h2')].map(element=>({text:element.textContent,size:getComputedStyle(element).fontSize,height:element.getBoundingClientRect().height})),
    codeLines:document.querySelectorAll('.md-code').length,tables:document.querySelectorAll('.md-table table').length};},
  // Used by native integration tests: exercise the same transaction/input path.
  dispatch(change){
    if(change.selection?.ranges)change={...change,selection:EditorSelection.create(change.selection.ranges.map(range=>EditorSelection.range(range.anchor,range.head)),change.selection.main||0)};
    view.dispatch(change);
  },compositionStart(){composingBefore=raw.raw;send({type:'composition',active:true});view.dispatch({effects:setComposing.of(true)});},compositionEnd:compositionFinished,
};
send({type:'ready'});
