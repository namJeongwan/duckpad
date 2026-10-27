import {StateField} from '@codemirror/state';
import {Decoration,EditorView} from '@codemirror/view';
import {syntaxTree} from '@codemirror/language';
import {parser} from '@lezer/markdown';
import MarkdownIt from 'markdown-it';
import {updateDecorations,decorationUpdateRanges} from './editor-decoration-updates.mjs';

const markdown=new MarkdownIt(),reference=value=>value.replace(/^\[|\]$/g,'').trim().replace(/\s+/g,' ').toUpperCase();
function referenceEntries(doc,tree,start=0,end=doc.length) {
  const result=[];
  tree.iterate({from:start,to:end,enter({node,name,from,to}){
    if(to<start||from>end)return false;
    if(name==='LinkReference') {
      const label=node.getChild('LinkLabel'),url=node.getChild('URL');
      if(label&&url)result.push({from,to,key:reference(doc.sliceString(label.from,label.to)),href:doc.sliceString(url.from,url.to)});
      return false;
    }
    if(!['Document','BulletList','OrderedList','ListItem','Blockquote'].includes(name))return false;
  }});
  return result;
}
function definitionMap(entries) {
  const definitions=new Map();
  for(const entry of entries.sort((a,b)=>a.from-b.from))if(!definitions.has(entry.key))definitions.set(entry.key,entry.href);
  return definitions;
}
const references=StateField.define({create(state){
  const entries=referenceEntries(state.doc,syntaxTree(state));return {entries,definitions:definitionMap(entries)};
},update(value,tr){
  const affected=decorationUpdateRanges(tr);if(!affected.length)return value;
  const entries=value.entries.map(entry=>({...entry,from:tr.changes.mapPos(entry.from,-1),to:tr.changes.mapPos(entry.to,1)}))
    .filter(entry=>!affected.some(range=>entry.from<=range.to&&entry.to>=range.from));
  for(const range of affected)entries.push(...referenceEntries(tr.state.doc,syntaxTree(tr.state),range.from,range.to));
  const definitions=definitionMap(entries),same=definitions.size===value.definitions.size&&[...definitions].every(([key,href])=>value.definitions.get(key)===href);
  return {entries,definitions:same?value.definitions:definitions};
}});
function links(doc,tree,start=0,end=doc.length,definitions=definitionMap(referenceEntries(doc,tree))) {
  const slice=(from,to)=>doc.sliceString(from,to),result=[];
  tree.iterate({from:start,to:end,enter({node,name,from,to}){
    if(to<start||from>end)return false;
    if(name==='URL'&&!['Link','Image','Autolink','LinkReference'].includes(node.parent?.name)) {
      result.push({from,to,labelFrom:from,labelTo:to,markers:[],href:markdown.normalizeLink(slice(from,to))});return;
    }
    if(name!=='Link'&&name!=='Autolink')return;
    const markers=[];for(let child=node.firstChild;child;child=child.nextSibling)if(child.name==='LinkMark')markers.push(child);
    const url=node.getChild('URL'),suffix=node.getChild('LinkLabel');
    const labelFrom=name==='Autolink'?url?.from:markers[0]?.to,labelTo=name==='Autolink'?url?.to:markers[1]?.from;
    if(labelFrom==null||labelTo==null)return;
    const raw=url?slice(url.from,url.to):definitions.get(reference(suffix&&reference(slice(suffix.from,suffix.to))?slice(suffix.from,suffix.to):slice(labelFrom,labelTo)));
    if(!raw)return;
    const destination=raw.startsWith('<')&&raw.endsWith('>')?raw.slice(1,-1):raw;
    const href=markdown.normalizeLink(markdown.utils.unescapeAll(name==='Autolink'&&/^[^:/]+@/.test(destination)?'mailto:'+destination:destination));
    result.push({from,to,labelFrom,labelTo,markers:markers.map(marker=>[marker.from,marker.to]),url,suffix,href});
  }});
  return result;
}
function decorations(state,start=0,end=state.doc.length) {
  const output=[];
  for(const link of links(state.doc,syntaxTree(state),start,end,state.field(references).definitions)) {
    const attributes={'data-md-href':link.href,title:link.href,role:'link'};
    if(link.labelTo>link.labelFrom)output.push(Decoration.mark({class:'md-link md-link-label',attributes}).range(link.labelFrom,link.labelTo));
    for(const [from,to] of link.markers)output.push(Decoration.mark({class:'md-link-marker'}).range(from,to));
    if(link.url&&link.url.from!==link.labelFrom)output.push(Decoration.mark({class:'md-link-destination',attributes}).range(link.url.from,link.url.to));
    if(link.suffix)output.push(Decoration.mark({class:'md-link-marker'}).range(link.suffix.from,link.suffix.to));
  }
  return Decoration.set(output,true);
}
// Source and Live share link targets; Live alone hides the delimiters.
const linkMarks=StateField.define({create:decorations,update(value,tr){
  if(tr.startState.field(references).definitions!==tr.state.field(references).definitions)return decorations(tr.state);
  return updateDecorations(value,tr,decorations);
},provide:field=>EditorView.decorations.from(field)});
export const linkPresentation=[references,linkMarks];

function hrefAtEvent(event) {
  const target=event.target.closest('[data-md-href],a[href]');
  if(target)return target.getAttribute('data-md-href')??target.getAttribute('href');
  const input=event.target;
  if(input.classList?.contains('md-table-cell-input')) {
    const doc={sliceString:(from,to)=>input.value.slice(from,to)};
    return links(doc,parser.parse(input.value)).find(link=>input.selectionStart>=link.from&&input.selectionStart<=link.to)?.href;
  }
}
export function linkMouseDown(event) {
  if(event.button!==0||!event.metaKey||event.isComposing||!event.target.closest('[data-md-href],a[href]'))return false;
  event.preventDefault();return true;
}
export function linkClick(event) {
  if(event.button!==0||!event.metaKey||event.isComposing)return false;
  const href=hrefAtEvent(event);if(!href)return false;
  event.preventDefault();event.stopPropagation();
  void window.DuckpadEditorHost?.({type:'openLink',href});return true;
}
