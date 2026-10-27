import {StateEffect, StateField} from '@codemirror/state';
import {Decoration, EditorView, WidgetType} from '@codemirror/view';
import {syntaxTree} from '@codemirror/language';
import {EditableTable} from './editor-table.mjs';
import {DiagramPreview} from './editor-diagram.mjs';
import {MathPreview} from './editor-math.mjs';
import {updateDecorations} from './editor-decoration-updates.mjs';

export const setLive = StateEffect.define(), setComposing = StateEffect.define(), setDragging = StateEffect.define();
export const liveMode = StateField.define({create: () => true, update(value, tr) {
  for (const effect of tr.effects) if (effect.is(setLive)) value = effect.value;
  return value;
}});
const composition = StateField.define({create: () => false, update(value, tr) {
  for (const effect of tr.effects) if (effect.is(setComposing)) value = effect.value;
  return value;
}});
const dragging = StateField.define({create:()=>false,update(value,tr){
  for(const effect of tr.effects)if(effect.is(setDragging))value=effect.value;
  return value;
}});
const selected = (state, from, to) => {
  const ranges=state.selection.ranges;let low=0,high=ranges.length;
  while(low<high){const middle=(low+high)>>1;if(ranges[middle].to<from)low=middle+1;else high=middle;}
  return low<ranges.length&&ranges[low].from<=to;
};
const active=selected;
const marks = (node, name) => { const result=[]; for(let child=node.firstChild;child;child=child.nextSibling) if(child.name===name) result.push(child); return result; };
const moveTo = (view, position) => { view.dispatch({selection:{anchor:position}, scrollIntoView:true}); view.focus(); };

class Bullet extends WidgetType {
  eq() { return true; }
  toDOM() { const span=document.createElement('span'); span.className='md-bullet'; span.textContent='•'; return span; }
}
class Checkbox extends WidgetType {
  constructor(checked, position, label) { super(); Object.assign(this,{checked,position,label}); }
  eq(other) { return this.checked===other.checked && this.position===other.position && this.label===other.label; }
  toDOM(view) {
    const box=document.createElement('input'); box.type='checkbox';box.checked=this.checked;box.className='md-task';
    box.setAttribute('aria-label', this.label);
    box.addEventListener('mousedown', event=>{ event.preventDefault();if(view.state.readOnly)return;
      view.dispatch({changes:{from:view.posAtDOM(box)+1,to:view.posAtDOM(box)+2,insert:this.checked?' ':'x'}}); });
    return box;
  }
  ignoreEvent() { return false; }
}
class CodeHeader extends WidgetType {
  constructor(language, text, position, anchor) { super(); Object.assign(this,{language,text,position,anchor}); }
  eq(other) { return this.language===other.language&&this.text===other.text&&this.position===other.position&&this.anchor===other.anchor; }
  toDOM(view) {
    const header=document.createElement('div');header.className='md-code-header';
    const language=document.createElement('span');language.textContent=this.language;
    language.addEventListener('mousedown',e=>{e.preventDefault();moveTo(view,view.posAtDOM(header)+(this.position-this.anchor));});
    const copy=document.createElement('button');copy.textContent=window.DuckpadEditorLabels?.copy||'Copy';
    copy.addEventListener('mousedown', e=>{ e.preventDefault();window.DuckpadEditorHost?.({type:'copy',text:this.text}); });
    header.append(language,copy);return header;
  }
  ignoreEvent() { return false; }
}
class RenderedBlock extends WidgetType {
  constructor(source, position, kind) { super();Object.assign(this,{source,position,kind}); }
  eq(other) { return this.source===other.source&&this.position===other.position&&this.kind===other.kind; }
  toDOM(view) {
    const wrapper=document.createElement('div');wrapper.className=this.kind==='table'?'md-table':'md-rule';
    wrapper.addEventListener('mousedown', event=>{event.preventDefault();moveTo(view,view.posAtDOM(wrapper));});
    return wrapper;
  }
  ignoreEvent() { return false; }
}
class ImageWidget extends WidgetType {
  constructor(source, alt, position) { super(); Object.assign(this,{source,alt,position,base:window.DuckpadEditorDocumentURL}); }
  eq(other) { return this.source===other.source&&this.alt===other.alt&&this.position===other.position&&this.base===other.base; }
  toDOM(view) {
    const image=document.createElement('img');image.className='md-image';image.alt=this.alt;
    try {
      const url=new URL(this.source,window.DuckpadEditorDocumentURL||'duckpad-editor://assets/');
      if(url.protocol==='file:') image.src='duckpad-editor://local?url='+encodeURIComponent(url.href);
      else if(url.protocol==='data:'&&/^data:image\/(png|jpeg|gif|webp);base64,/i.test(this.source)) image.src=url.href;
    } catch {}
    image.addEventListener('mousedown',e=>{e.preventDefault();moveTo(view,view.posAtDOM(image));});return image;
  }
  ignoreEvent() { return false; }
}

function decorations(state,start=0,end=state.doc.length) {
  if(!state.field(liveMode)||state.field(composition)) return Decoration.none;
  const output=[], lines=new Map(),doc=state.doc;
  const line=(position,cls,style='')=>{
    const from=doc.lineAt(position).from, previous=lines.get(from)||{classes:new Set(),styles:[]};
    previous.classes.add(cls); if(style)previous.styles.push(style);lines.set(from,previous);
  };
  const hide=(from,to,block=false)=>{if(to>from)output.push(Decoration.replace({block,inclusive:false}).range(from,to));};
  syntaxTree(state).iterate({from:start,to:end,enter(ref){
    const node=ref.node, {name,from,to}=node;
    if(to<start||from>end)return false;
    if(name==='MathInline'||name==='MathBlock') {
      const delimiters=marks(node,'MathMark'),display=name==='MathBlock',closed=delimiters.length===2;
      if(closed) {
        const source=doc.sliceString(delimiters[0].to,delimiters[1].from),editing=selected(state,from,to);
        if(!editing)output.push(Decoration.replace({block:display,inclusive:false,widget:new MathPreview(source,display,delimiters[0].to-from)}).range(from,to));
        else if(display)output.push(Decoration.widget({block:true,side:1,widget:new MathPreview(source,true,delimiters[0].to-to)}).range(to));
      }
      return false;
    } else if(/^(ATX|Setext)Heading[1-6]$/.test(name)) {
      line(from,'md-h'+name.at(-1));
      if(!active(state,doc.lineAt(from).from,to)) for(const marker of marks(node,'HeaderMark')) {
        let end=marker.to;while(end<to&&doc.sliceString(end,end+1)===' ')end++;
        hide(marker.from,end);
      }
    } else if(name==='Paragraph') {
      line(from,'md-paragraph-start');line(to,'md-paragraph-end');
    } else if(name==='StrongEmphasis'||name==='Emphasis'||name==='Strikethrough') {
      output.push(Decoration.mark({class:name==='StrongEmphasis'?'md-bold':name==='Emphasis'?'md-italic':'md-strike'}).range(from,to));
      if(!active(state,from,to)) for(const marker of marks(node,name==='Strikethrough'?'StrikethroughMark':'EmphasisMark')) hide(marker.from,marker.to);
    } else if(name==='InlineCode') {
      output.push(Decoration.mark({class:'md-inline-code'}).range(from,to));
      if(!active(state,from,to)) for(const marker of marks(node,'CodeMark'))hide(marker.from,marker.to);
      return false;
    } else if(name==='ListItem') {
      let depth=0;for(let parent=node;parent;parent=parent.parent)if(parent.name==='ListItem')depth++;
      line(from,'md-list',`padding-left:${depth*24}px;text-indent:-24px`);
      const marker=node.getChild('ListMark'),row=doc.lineAt(from);
      if(marker&&!active(state,row.from,marker.to)) {
        hide(row.from,marker.from);
        const task=node.getChild('Task');
        if(task?.getChild('TaskMarker'))hide(marker.from,marker.to);
        else if(node.parent?.name==='BulletList')output.push(Decoration.replace({widget:new Bullet()}).range(marker.from,marker.to));
      }
    } else if(name==='TaskMarker'&&!active(state,from,to)) {
      output.push(Decoration.replace({widget:new Checkbox(/x/i.test(doc.sliceString(from,to)),from,doc.lineAt(from).text)}).range(from,to));return false;
    } else if(name==='Blockquote') {
      const first=doc.lineAt(from).number,last=doc.lineAt(to).number;
      for(let index=first;index<=last;index++)line(doc.line(index).from,'md-quote');
    } else if(name==='QuoteMark'&&!active(state,from,to)) {
      let end=to;if(doc.sliceString(end,end+1)===' ')end++;hide(from,end);
    } else if(name==='FencedCode'||name==='CodeBlock') {
      const first=doc.lineAt(from),last=doc.lineAt(to),fenced=name==='FencedCode';
      const delimiters=marks(node,'CodeMark'),info=node.getChild('CodeInfo');
      const closed=fenced&&delimiters.length>=2;
      const bodyFirst=first.number+(fenced?1:0),bodyLast=last.number-(closed?1:0);
      const language=info?doc.sliceString(info.from,info.to).trim().split(/\s+/)[0].toLowerCase():'';
      if(fenced&&language==='math'&&closed&&bodyFirst<=bodyLast) {
        const editing=selected(state,from,to),source=doc.sliceString(doc.line(bodyFirst).from,doc.line(bodyLast).to);
        const anchor=editing?to:from,widget=new MathPreview(source,true,doc.line(bodyFirst).from-anchor);
        if(!editing){output.push(Decoration.replace({block:true,inclusive:false,widget}).range(from,Math.min(doc.length,to+1)));return false;}
        output.push(Decoration.widget({block:true,side:1,widget}).range(to));
      }
      if(fenced&&language==='mermaid'&&bodyFirst<=bodyLast) {
        const editing=selected(state,from,to)||!closed;
        const widget=new DiagramPreview(doc.sliceString(doc.line(bodyFirst).from,doc.line(bodyLast).to),doc.line(bodyFirst).from,editing,editing?to:from);
        if(!editing) {
          output.push(Decoration.replace({block:true,inclusive:false,widget}).range(from,Math.min(doc.length,to+1)));return false;
        }
        output.push(Decoration.widget({block:true,side:1,widget}).range(to));
      }
      for(let index=bodyFirst;index<=bodyLast;index++) {
        line(doc.line(index).from,'md-code');
        if(index===bodyFirst)line(doc.line(index).from,'md-code-first');
        if(index===bodyLast)line(doc.line(index).from,'md-code-last');
      }
      if(fenced) {
        const reveal=selected(state,from,to);
        if(reveal) { line(from,'md-fence');if(closed)line(last.from,'md-fence'); }
        else {
          hide(first.from,Math.min(doc.length,first.to+1),true);
          if(closed)hide(last.from,last.to,true);
          if(bodyFirst<=bodyLast) {
            const text=doc.sliceString(doc.line(bodyFirst).from,doc.line(bodyLast).to);
            output.push(Decoration.widget({block:true,side:-1,widget:new CodeHeader(info?doc.sliceString(info.from,info.to):'',text,first.from,doc.line(bodyFirst).from)}).range(doc.line(bodyFirst).from));
          }
        }
      }
    } else if(name==='Table') {
      output.push(Decoration.replace({block:true,inclusive:false,widget:new EditableTable(doc.sliceString(from,to),from,state.readOnly)}).range(from,Math.min(doc.length,to+1)));return false;
    } else if(name==='HorizontalRule'&&!active(state,from,to)) {
      output.push(Decoration.replace({block:true,widget:new RenderedBlock('',from,'rule')}).range(from,to));return false;
    } else if(name==='Image'&&!selected(state,from,to)) {
      const url=node.getChild('URL');if(url){
        const source=doc.sliceString(from,to),alt=source.match(/^!\[([^\]]*)\]/)?.[1]||'';
        const block=doc.lineAt(from).from===from&&doc.lineAt(to).to===to;
        output.push(Decoration.replace({block,widget:new ImageWidget(doc.sliceString(url.from,url.to),alt,from)}).range(from,to));
      }return false;
    } else if((name==='Link'||name==='Autolink')&&!active(state,from,to)) {
      const markers=marks(node,'LinkMark');
      if(markers.length>=2){hide(markers[0].from,markers[0].to);hide(markers[1].from,to);}
    }
  }});
  for(const [position,value] of lines)output.push(Decoration.line({class:[...value.classes].join(' '),attributes:{style:value.styles.join(';')}}).range(position));
  return Decoration.set(output,true);
}
const presentation=StateField.define({create:decorations,update(value,tr){
  if(tr.startState.readOnly!==tr.state.readOnly)return decorations(tr.state);
  if(tr.state.field(composition))return value.map(tr.changes);
  if(tr.state.field(dragging))return value.map(tr.changes);
  if(tr.effects.some(effect=>effect.is(setLive)||effect.is(setComposing)||effect.is(setDragging)))return decorations(tr.state);
  return updateDecorations(value,tr,decorations,true);
},provide:field=>EditorView.decorations.from(field)});
export const liveExtensions=[liveMode,composition,dragging,presentation,
  EditorView.editorAttributes.compute([liveMode],state=>({class:state.field(liveMode)?'md-live':'md-source'}))];
