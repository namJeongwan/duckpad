import {findClusterBreak} from '@codemirror/state';

// A textarea does not expose caret rectangles. Mirror only its text layout so
// Up/Down can distinguish a wrapped line from the top/bottom of the cell.
function mirrorInput(input,read) {
  const style=getComputedStyle(input),bounds=input.getBoundingClientRect(),mirror=document.createElement('div');
  for(const property of ['font','letterSpacing','lineHeight','textAlign','textIndent','padding','border','boxSizing','tabSize','wordBreak','overflowWrap'])mirror.style[property]=style[property];
  Object.assign(mirror.style,{position:'fixed',left:'-100000px',top:'0',width:bounds.width+'px',height:'auto',
    whiteSpace:'pre-wrap',overflowWrap:'break-word',visibility:'hidden',pointerEvents:'none',margin:'0'});
  const text=document.createTextNode(input.value+'\u200b');mirror.append(text);document.body.append(mirror);
  const origin=mirror.getBoundingClientRect(),range=document.createRange();
  const caret=position=>{
    range.setStart(text,position);range.setEnd(text,Math.min(text.length,position+1));const rect=range.getBoundingClientRect();
    return {x:bounds.left+rect.left-origin.left-input.scrollLeft,top:rect.top-origin.top};
  };
  try{return read(caret,parseFloat(style.lineHeight)||parseFloat(style.fontSize)*1.5);}
  finally{mirror.remove();}
}

export function inputCaret(input) {
  return mirrorInput(input,(caret,lineHeight)=>{
    const current=caret(input.selectionStart),first=caret(0),last=caret(input.value.length);
    return {x:current.x,firstLine:current.top<first.top+lineHeight/2,lastLine:current.top>last.top-lineHeight/2};
  });
}

export function placeInputCaret(input,placement) {
  let position=placement.edge==='end'?input.value.length:0;
  if(placement.x!==undefined)position=mirrorInput(input,(caret,lineHeight)=>{
    const positions=[0];
    while(positions.at(-1)<input.value.length)positions.push(findClusterBreak(input.value,positions.at(-1),true));
    const target=caret(placement.edge==='end'?input.value.length:0).top;
    let low=0,high=positions.length;
    while(low<high){const middle=(low+high)>>1;if(caret(positions[middle]).top<target-lineHeight/2)low=middle+1;else high=middle;}
    let best=positions[low]??input.value.length,distance=Infinity;
    for(let index=low;index<positions.length;index++) {
      const rect=caret(positions[index]);if(rect.top>target+lineHeight/2)break;
      const delta=Math.abs(rect.x-placement.x);if(delta<distance){best=positions[index];distance=delta;}
    }
    return best;
  });
  input.setSelectionRange(position,position);
}
