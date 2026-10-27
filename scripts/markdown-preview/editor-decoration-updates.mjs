import {syntaxTree} from '@codemirror/language';

function blockAt(state,position,side) {
  const tree=syntaxTree(state),point=Math.max(0,Math.min(state.doc.length,position));
  let node=tree.resolveInner(point,side);
  while(node.parent&&node.parent.name!=='Document')node=node.parent;
  if(node.name==='Document')node=node.childBefore(point)||node.childAfter(point)||node;
  return {from:node.from,to:node.to};
}
function owner(state,from,to) {
  const first=blockAt(state,from-1,-1),last=blockAt(state,to+1,1);
  return {from:state.doc.lineAt(Math.min(first.from,from)).from,
    to:state.doc.lineAt(Math.max(last.to,to)).to};
}
function cover(state,from,to) {
  const first=blockAt(state,from,1),last=blockAt(state,to,-1);
  return {from:state.doc.lineAt(Math.min(first.from,from)).from,
    to:state.doc.lineAt(Math.max(last.to,to)).to};
}
function ownershipClosure(tr,range) {
  const inverse=tr.changes.invertedDesc;
  while(true) {
    const old=cover(tr.startState,inverse.mapPos(range.from,-1),inverse.mapPos(range.to,1));
    const next=cover(tr.state,Math.min(range.from,tr.changes.mapPos(old.from,-1)),
      Math.max(range.to,tr.changes.mapPos(old.to,1)));
    if(next.from===range.from&&next.to===range.to)return range;
    range=next;
  }
}

function merge(ranges) {
  const result=[];
  for(const range of ranges.sort((a,b)=>a.from-b.from)) {
    const last=result.at(-1);
    if(last&&range.from<=last.to+1)last.to=Math.max(last.to,range.to);
    else result.push({...range});
  }
  return result;
}
const sameSelection=(a,b)=>a.ranges.length===b.ranges.length&&a.ranges.every((range,index)=>range.anchor===b.ranges[index].anchor&&range.head===b.ranges[index].head);

// Preserve decorations outside the Markdown blocks affected by an edit or
// caret move. Parser background updates compare shared root children instead
// of walking every syntax node again.
export function decorationUpdateRanges(tr,selectionSensitive=false) {
  const ranges=[];
  tr.changes.iterChangedRanges((oldFrom,oldTo,from,to)=>{
    const old=owner(tr.startState,oldFrom,oldTo);
    ranges.push(owner(tr.state,from,to),owner(tr.state,tr.changes.mapPos(old.from,-1),tr.changes.mapPos(old.to,1)));
  });
  if(selectionSensitive&&!sameSelection(tr.startState.selection,tr.state.selection)) {
    for(const range of tr.startState.selection.ranges)ranges.push(owner(tr.state,tr.changes.mapPos(range.from,-1),tr.changes.mapPos(range.to,1)));
    for(const range of tr.state.selection.ranges)ranges.push(owner(tr.state,range.from,range.to));
  }
  const previous=syntaxTree(tr.startState),next=syntaxTree(tr.state);
  if(!tr.docChanged&&previous!==next) {
    const oldByPosition=new Map(previous.children.map((child,index)=>[previous.positions[index],child]));
    const newByPosition=new Map(next.children.map((child,index)=>[next.positions[index],child]));
    for(const [from,child] of newByPosition)if(oldByPosition.get(from)!==child)ranges.push(owner(tr.state,from,from+child.length));
    for(const [from,child] of oldByPosition)if(newByPosition.get(from)!==child)ranges.push(owner(tr.state,from,Math.min(tr.state.doc.length,from+child.length)));
  }
  const merged=merge(ranges);
  return tr.docChanged||previous!==next?merge(merged.map(range=>ownershipClosure(tr,range))):merged;
}

export function updateDecorations(value,tr,build,selectionSensitive=false) {
  const mapped=value.map(tr.changes),affected=decorationUpdateRanges(tr,selectionSensitive),add=[];
  if(!affected.length)return mapped;
  for(const range of affected)build(tr.state,range.from,range.to).between(0,tr.state.doc.length,(from,to,value)=>add.push(value.range(from,to)));
  return mapped.update({filter:(from,to)=>!affected.some(range=>from<=range.to&&to>=range.from),add,sort:true});
}
