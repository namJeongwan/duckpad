import test from 'node:test';
import assert from 'node:assert/strict';
import {EditorState} from '@codemirror/state';
import {EditorView} from '@codemirror/view';
import {markdown} from '@codemirror/lang-markdown';
import {GFM} from '@lezer/markdown';
import {liveExtensions,setDragging} from './editor-live.mjs';
import {linkPresentation} from './editor-link.mjs';
import {mathSyntax} from './editor-math.mjs';

globalThis.window={};
globalThis.document={body:{dataset:{theme:'dark'}}};
const extensions=[markdown({extensions:[GFM,mathSyntax]}),linkPresentation,liveExtensions];
const create=(doc,selection)=>EditorState.create({doc,selection,extensions});
function snapshot(state) {
  const result=[];
  for(const set of state.facet(EditorView.decorations))set.between(0,state.doc.length,(from,to,value)=>{
    const {widget,...spec}=value.spec;
    const rendered=widget?Object.fromEntries(['source','readOnly','checked','language','text','editing','kind','alt'].filter(key=>key in widget).map(key=>[key,widget[key]])):undefined;
    result.push(JSON.stringify({from,to,spec,widget:rendered}));
  });
  return result.sort();
}
const source='# Heading\n\nParagraph **bold** and [link][ref].\n\n- [ ] task\n- nested `code`\n\n| A | B |\n| --- | --- |\n| one | two |\n\n```swift\nlet n = 42\n```\n\n[ref]: ../old.rs\n\nEnd';

test('incremental Markdown decorations equal fresh rendering after structural edits and selection changes',()=>{
  for(const initialSeed of [1,7,73,184,8192]) {
  let state=create(source,{anchor:source.length}),seed=initialSeed;
  const random=max=>{seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed%max;};
  const inserts=['a','\n','**','[x](file.md)','\n- item\n','| a | b |','```','$$',' $x$ ',''];
  for(let index=0;index<160;index++) {
    if(index%3===0)state=state.update({selection:{anchor:random(state.doc.length+1),head:random(state.doc.length+1)}}).state;
    else {
      const from=random(state.doc.length+1),to=Math.min(state.doc.length,from+random(9));
      state=state.update({changes:{from,to,insert:inserts[random(inserts.length)]}}).state;
    }
    assert.deepEqual(snapshot(state),snapshot(create(state.doc,state.selection)),`seed ${initialSeed} transaction ${index}`);
  }
  }
});

test('pointer selection preserves existing markup until release, including its starting block',()=>{
  let state=create(source,{anchor:source.indexOf('bold')});
  const initial=snapshot(state);
  state=state.update({effects:setDragging.of(true)}).state;
  for(let head=0;head<source.length;head+=7) {
    state=state.update({selection:{anchor:0,head}}).state;
    assert.deepEqual(snapshot(state),initial);
  }
  state=state.update({effects:setDragging.of(false)}).state;
  assert.deepEqual(snapshot(state),snapshot(create(state.doc,state.selection)));
});

test('reference definitions propagate across unchanged blocks and prefix edits',()=>{
  let state=create(source,{anchor:source.length});
  for(const change of [{from:0,insert:'prefix\n\n'},{from:source.indexOf('../old.rs')+8,to:source.indexOf('../old.rs')+8+9,insert:'https://example.com/new'}]) {
    state=state.update({changes:change}).state;
    assert.deepEqual(snapshot(state),snapshot(create(state.doc,state.selection)));
  }
});


test('indented paragraph caret updates never accumulate line decorations',()=>{
  let state=create(' x',{anchor:1,head:2});
  for(let index=0;index<80;index++) {
    state=state.update({selection:index%2?{anchor:1,head:2}:{anchor:1}}).state;
    assert.deepEqual(snapshot(state),snapshot(create(state.doc,state.selection)));
  }
});


test('opening a fence before an existing unclosed fence invalidates every reclassified block',()=>{
  for(const delimiter of ['```','$$']) {
    let state=create('a\n\n'+delimiter+'\n\nb');
    state=state.update({changes:{from:0,insert:delimiter+'\n'}}).state;
    assert.deepEqual(snapshot(state),snapshot(create(state.doc,state.selection)));
  }
});
