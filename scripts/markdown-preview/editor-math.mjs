import {WidgetType} from '@codemirror/view';
import katex from 'katex';

const escaped=(text,index)=>{let count=0;while(index>0&&text[--index]==='\\')count++;return count%2===1;};
export const mathSyntax={
  defineNodes:[{name:'MathBlock',block:true},'MathInline','MathMark'],
  parseInline:[{name:'MathInline',after:'InlineCode',parse(cx,next,pos){
    if(next!==36||cx.char(pos+1)===36||cx.char(pos-1)===36||/\s/.test(cx.slice(pos+1,pos+2))||pos+1===cx.end)return -1;
    // A currency amount followed by another amount is ordinary text.
    if(/[\w]/.test(cx.slice(pos-1,pos)))return -1;
    for(let end=pos+1;end<cx.end;end++) {
      if(cx.char(end)===10)return -1;
      if(cx.char(end)===36&&!escaped(cx.text,end-cx.offset)&&cx.char(end+1)!==36&&!/[\d]/.test(cx.slice(end+1,end+2))&&!/\s/.test(cx.slice(end-1,end)))
        return cx.addElement(cx.elt('MathInline',pos,end+1,[cx.elt('MathMark',pos,pos+1),cx.elt('MathMark',end,end+1)]));
    }
    return -1;
  }}],
  parseBlock:[{name:'MathBlock',before:'FencedCode',parse(cx,line){
    if(line.next!==36||!line.text.slice(line.pos).startsWith('$$')||line.text[line.pos+2]==='$')return false;
    const from=cx.lineStart+line.pos,children=[cx.elt('MathMark',from,from+2)];
    let end=line.text.indexOf('$$',line.pos+2),to;
    if(end>=0&&line.text.slice(end+2).trim()==='') {
      to=cx.lineStart+end+2;children.push(cx.elt('MathMark',to-2,to));cx.nextLine();
    } else {
      to=cx.lineStart+line.text.length;
      while(cx.nextLine()) {
        if(/^\s*\$\$\s*$/.test(line.text.slice(line.basePos))) {
          const close=cx.lineStart+line.text.indexOf('$$',line.basePos);
          to=close+2;children.push(cx.elt('MathMark',close,to));cx.nextLine();break;
        }
        to=cx.lineStart+line.text.length;
      }
    }
    cx.addElement(cx.elt('MathBlock',from,to,children));return true;
  },endLeaf:(_cx,line)=>line.text.slice(line.pos).startsWith('$$')}]
};

export class MathPreview extends WidgetType {
  constructor(source,display,offset=0){super();Object.assign(this,{source,display,offset});}
  eq(other){return this.source===other.source&&this.display===other.display&&this.offset===other.offset;}
  toDOM(view){
    const element=document.createElement(this.display?'div':'span');element.className=this.display?'md-math md-math-block':'md-math md-math-inline';
    // KaTeX owns the markup; document HTML and trusted TeX commands stay off.
    katex.render(this.source,element,{displayMode:this.display,throwOnError:false,trust:false,maxExpand:1000,maxSize:20,output:'htmlAndMathml'});
    element.addEventListener('mousedown',event=>{
      if(event.button!==0)return;
      event.preventDefault();const position=view.posAtDOM(element)+this.offset;
      view.dispatch({selection:{anchor:position},scrollIntoView:true});view.focus();
    });return element;
  }
  ignoreEvent(){return true;}
}
