import {EditorSelection} from '@codemirror/state';
import {WidgetType} from '@codemirror/view';
import MarkdownIt from 'markdown-it';
import katexPlugin from '@vscode/markdown-it-katex';
import DOMPurify from 'dompurify';
import {tableModel,changeCell,changeTable,displayCell,encodeCell} from './editor-table-model.mjs';
import {inputCaret,placeInputCaret} from './editor-table-caret.mjs';
import {linkMouseDown,linkClick} from './editor-link.mjs';

const markdown=new MarkdownIt({html:false,linkify:false,breaks:false}).use(katexPlugin.default??katexPlugin,{throwOnError:false,trust:false,maxExpand:1000,maxSize:20});
// Native selection echoes carry offsets only. Keep the exit column for an
// immediate reverse arrow, including tables whose column widths change on blur.
const controllers=new WeakMap(),exitGoals=new WeakMap();
const label=key=>window.DuckpadEditorLabels?.[key]||'';
const sameChange=(view,change)=>view.state.doc.sliceString(change.from,change.to??change.from)===change.insert;

export function commitTableInput(view) {
  for(const controller of controllers.get(view)||[])controller.commit();
}

export function enterTableWithArrow(view,key) {
  const tables=controllers.get(view);
  if(!tables?.size||view.state.readOnly||view.composing||view.state.selection.ranges.length!==1||!view.state.selection.main.empty)return false;
  const selection=view.state.selection.main,forward=key==='ArrowDown'||key==='ArrowRight',vertical=key==='ArrowDown'||key==='ArrowUp';
  const next=vertical?view.moveVertically(selection,forward):view.moveByChar(selection,forward);
  const candidates=[...tables].filter(controller=>{
    controller.rebase();
    const {from,to}=controller.model,head=selection.head;
    return head>=from&&head<=to||(forward?head<from&&next.head>=from:head>to&&next.head<=to+1);
  }).sort((a,b)=>forward?a.model.from-b.model.from:b.model.from-a.model.from);
  const controller=candidates[0];if(!controller)return false;
  const row=forward?0:controller.model.rows.length-1;
  let column=forward?0:controller.model.columns-1,x;
  if(vertical) {
    const origin=view.contentDOM.getBoundingClientRect(),hint=exitGoals.get(view);
    const exit=hint?.doc===view.state.doc&&hint.head===selection.head&&hint.from===controller.model.from?hint:null;
    x=exit?exit.x:selection.goalColumn==null?view.coordsAtPos(selection.head)?.left:origin.left+selection.goalColumn;
    if(exit)column=Math.min(exit.column,controller.model.columns-1);
    else if(x!==undefined) {
      let closest=Infinity;
      controller.cells[row].forEach((record,index)=>{
        const bounds=record.cell.getBoundingClientRect(),distance=Math.max(bounds.left-x,x-bounds.right,0);
        if(distance<closest){column=index;closest=distance;}
      });
    }
  }
  exitGoals.delete(view);controller.activate(row,column,{edge:forward?'start':'end',x});return true;
}

export async function tableCommand(view,command) {
  const input=document.activeElement;
  if(!input?.classList.contains('md-table-cell-input'))return false;
  const controller=input.closest('.md-editable-table')?.tableController;
  if(!controller||controller.view!==view)return false;
  const start=input.selectionStart,end=input.selectionEnd;
  if(command==='selectAll'){input.select();controller.syncSelection();return true;}
  if(command==='copy'||command==='cut') {
    if(start===end)return true;
    await window.DuckpadEditorHost({type:'copy',text:input.value.slice(start,end)});
    if(!input.isConnected)return true;
    if(command==='cut'&&!view.state.readOnly){input.setRangeText('',start,end,'end');controller.commit();}
    return true;
  }
  if(command==='paste') {
    if(view.state.readOnly)return true;
    const clipboard=await window.DuckpadEditorHost({type:'clipboardRead'});
    if(!input.isConnected||document.activeElement!==input)return true;
    if(clipboard.text){input.setRangeText(clipboard.text.replace(/\r\n?|\n/g,' '),start,end,'end');controller.commit();}
    return true;
  }
  if(command==='delete') {
    if(!view.state.readOnly) {
      const limit=start===end?start+(start<input.value.length?String.fromCodePoint(input.value.codePointAt(start)).length:0):end;
      input.setRangeText('',start,limit,'end');controller.commit();
    }
    return true;
  }
  return false;
}

class TableController {
  constructor(view,model) {
    this.view=view;this.model=model;this.row=0;this.column=0;this.composing=false;
    this.root=document.createElement('div');this.root.className='md-table md-editable-table';
    this.root.dataset.tableFrom=String(model.from);
    this.menuButton=document.createElement('button');this.menuButton.type='button';this.menuButton.className='md-table-menu-button';
    this.menuButton.textContent='⋯';this.menuButton.setAttribute('aria-haspopup','menu');this.menuButton.setAttribute('aria-expanded','false');
    this.menuButton.addEventListener('mousedown',event=>event.preventDefault());
    this.menuButton.addEventListener('click',event=>{
      const open=!this.root.classList.contains('menu-open');this.setMenu(open);
      if(open&&event.detail===0)this.toolbar.querySelector('button:not(:disabled)')?.focus({preventScroll:true});
    });
    this.toolbar=document.createElement('div');this.toolbar.className='md-table-toolbar';this.toolbar.setAttribute('role','menu');
    this.buttons={};
    for(const action of ['cut','copy','paste','selectAll','insertRow','insertColumn','deleteRow','deleteColumn']) {
      const button=document.createElement('button');button.type='button';
      button.setAttribute('role','menuitem');
      button.dataset.action=action;
      button.addEventListener('mousedown',event=>event.preventDefault());
      button.addEventListener('click',()=>{
        this.setMenu(false);this.cells[this.row][this.column].input.focus({preventScroll:true});
        if(['cut','copy','paste','selectAll'].includes(action))void tableCommand(this.view,action);
        else this.action(action);
      });
      this.buttons[action]=button;this.toolbar.append(button);
    }
    this.table=document.createElement('table');
    const scroll=document.createElement('div');scroll.className='md-table-scroll';scroll.append(this.table);
    this.root.append(this.menuButton,this.toolbar,scroll);
    this.root.addEventListener('click',linkClick);
    this.root.addEventListener('contextmenu',event=>{
      const cell=event.target.closest('th,td');if(!cell||view.state.readOnly)return;
      event.preventDefault();
      const input=this.cells[cell.parentElement.rowIndex]?.[cell.cellIndex]?.input;
      if(document.activeElement!==input)this.activate(cell.parentElement.rowIndex,cell.cellIndex);
      this.setMenu(true,{x:event.clientX,y:event.clientY});
    });
    this.root.addEventListener('keydown',event=>{
      if(!this.root.classList.contains('menu-open'))return;
      if(event.key==='Escape') {
        event.preventDefault();event.stopPropagation();this.setMenu(false);this.cells[this.row][this.column].input.focus({preventScroll:true});
      } else if(event.key==='ArrowDown'||event.key==='ArrowUp') {
        event.preventDefault();event.stopPropagation();
        const buttons=Object.values(this.buttons).filter(button=>!button.disabled);
        const index=buttons.indexOf(document.activeElement),next=(index+(event.key==='ArrowDown'?1:-1)+buttons.length)%buttons.length;
        buttons[next]?.focus({preventScroll:true});
      }
    },true);
    this.root.addEventListener('focusout',()=>queueMicrotask(()=>{if(!this.root.contains(document.activeElement))this.setMenu(false);}));
    this.outside=event=>{if(!this.toolbar.contains(event.target)&&!this.menuButton.contains(event.target))this.setMenu(false);};
    document.addEventListener('mousedown',this.outside);
    this.sync(model);
    if(!controllers.has(view))controllers.set(view,new Set());
    controllers.get(view).add(this);
  }

  sync(model) {
    this.model=model;this.root.dataset.tableFrom=String(model.from);
    const rebuild=!this.cells||this.cells.length!==model.rows.length||this.cells[0].length!==model.columns;
    if(rebuild) {
      this.rebuilding=true;this.table.replaceChildren();this.cells=[];
      for(let row=0;row<model.rows.length;row++) {
        const section=document.createElement(row===0?'thead':'tbody'),tr=document.createElement('tr'),cells=[];
        for(let column=0;column<model.columns;column++) {
          const cell=document.createElement(row===0?'th':'td');cell.className='md-table-cell';
          const preview=document.createElement('div');preview.className='md-table-cell-preview';
          const input=document.createElement('textarea');input.className='md-table-cell-input';
          input.rows=1;input.spellcheck=false;input.dataset.row=String(row);input.dataset.column=String(column);
          cell.append(preview,input);tr.append(cell);cells.push({cell,preview,input});
          preview.addEventListener('mousedown',event=>{if(linkMouseDown(event))return;if(event.button!==0||this.view.state.readOnly)return;event.preventDefault();this.activate(row,column);});
          input.addEventListener('focus',()=>{
            this.row=row;this.column=column;cell.classList.add('is-editing');this.refreshButtons();
            void window.DuckpadEditorHost?.({type:'focus'});
          });
          input.addEventListener('input',()=>{this.verticalGoal=undefined;if(!this.composing)this.commit();this.resize(input);});
          for(const event of ['select','keyup','mouseup'])input.addEventListener(event,()=>queueMicrotask(()=>this.syncSelection()));
          input.addEventListener('blur',()=>{
            if(this.rebuilding)return;
            this.commit();cell.classList.remove('is-editing');
          });
          input.addEventListener('compositionstart',event=>{
            event.stopPropagation();this.composing=true;window.DuckpadEditor.compositionStart();
          });
          input.addEventListener('compositionend',event=>{event.stopPropagation();this.commit();});
          input.addEventListener('keydown',event=>this.key(event,row,column));
        }
        section.append(tr);this.table.append(section);this.cells.push(cells);
      }
      this.rebuilding=false;
    }
    for(let row=0;row<model.rows.length;row++)for(let column=0;column<model.columns;column++) {
      const record=this.cells[row][column],{cell,preview,input}=record,source=model.rows[row].cells[column]?.source||'';
      cell.style.textAlign=model.alignments[column];
      if(record.source!==source){preview.innerHTML=DOMPurify.sanitize(markdown.renderInline(source));record.source=source;}
      const text=displayCell(source);
      if(!this.composing&&input.value!==text) {
        const start=input.selectionStart,end=input.selectionEnd;
        input.value=text;input.setSelectionRange(Math.min(start,text.length),Math.min(end,text.length));
      }
      input.readOnly=this.view.state.readOnly;
      input.setAttribute('aria-label',label('tableCell').replace('%1$d',String(row+1)).replace('%2$d',String(column+1)));
    }
    this.row=Math.min(this.row,model.rows.length-1);this.column=Math.min(this.column,model.columns-1);
    this.refreshButtons();
    this.root.classList.toggle('is-readonly',this.view.state.readOnly);
    if(this.view.state.readOnly)this.setMenu(false);
  }

  refreshButtons() {
    this.menuButton.title=label('tableOptions');this.menuButton.setAttribute('aria-label',label('tableOptions'));
    this.menuButton.disabled=this.view.state.readOnly;
    for(const [action,button] of Object.entries(this.buttons)) {
      button.textContent=label(action);button.title=label(action);
      button.disabled=this.view.state.readOnly||(action==='deleteRow'&&this.row===0)||(action==='deleteColumn'&&this.model.columns<=1);
    }
  }

  setMenu(open,point) {
    if(this.view.state.readOnly)open=false;
    this.root.classList.toggle('menu-open',open);this.menuButton.setAttribute('aria-expanded',String(open));
    if(open) {
      this.refreshButtons();
      const anchor=this.menuButton.getBoundingClientRect();
      const {width,height}=this.toolbar.getBoundingClientRect();
      const x=point?.x??anchor.right-width,y=point?.y??anchor.bottom;
      this.toolbar.style.left=Math.max(4,Math.min(x,innerWidth-width-4))+'px';
      this.toolbar.style.top=Math.max(4,Math.min(y,innerHeight-height-4))+'px';
    }
  }

  resize(input) {
    requestAnimationFrame(()=>{
      if(!input.isConnected)return;
      this.view.requestMeasure();
    });
  }

  rebase() {
    if(!this.root.isConnected||this.destroyed)return;
    const position=this.view.posAtDOM(this.root);
    if(position!==this.model.from)this.sync(tableModel(this.model.source,position));
  }

  activate(row,column,placement) {
    if(this.view.state.readOnly)return;
    this.commit();
    for(const records of this.cells)for(const record of records)record.cell.classList.remove('is-editing');
    const record=this.cells[row]?.[column];if(!record)return;
    this.row=row;this.column=column;record.cell.classList.add('is-editing');
    this.verticalGoal=placement?.x;
    record.input.focus({preventScroll:true});this.resize(record.input);this.refreshButtons();
    if(placement)placeInputCaret(record.input,placement);
    this.syncSelection();
    // Scroll only the chosen cell into the nearest visible area, never the
    // hidden Markdown selection underneath the block replacement.
    record.cell.scrollIntoView({block:'nearest',inline:'nearest'});
  }

  leave(forward,vertical,x) {
    const doc=this.view.state.doc;
    if(forward?this.model.to===doc.length:this.model.from===0)return;
    this.commit();this.cells[this.row][this.column].input.blur();
    let position=forward?this.model.to+1:this.model.from-1;
    if(vertical&&x!==undefined) {
      const rect=this.view.coordsAtPos(position);
      if(rect)position=this.view.posAtCoords({x,y:(rect.top+rect.bottom)/2})??position;
    }
    const goal=vertical&&x!==undefined?x-this.view.contentDOM.getBoundingClientRect().left:undefined;
    this.view.focus();
    this.view.dispatch({selection:EditorSelection.cursor(position,forward?1:-1,undefined,goal),scrollIntoView:true});
    if(vertical)exitGoals.set(this.view,{head:position,doc:this.view.state.doc,from:this.model.from,column:this.column,x});
  }

  arrow(event,row,column) {
    const input=this.cells[row][column].input;
    if(event.shiftKey||event.altKey||event.metaKey||event.ctrlKey||input.selectionStart!==input.selectionEnd)return false;
    const vertical=event.key==='ArrowUp'||event.key==='ArrowDown',forward=event.key==='ArrowDown'||event.key==='ArrowRight';
    let x;
    if(vertical) {
      const caret=inputCaret(input);x=this.verticalGoal??caret.x;this.verticalGoal=x;
      if(forward?!caret.lastLine:!caret.firstLine)return false;
    } else {
      this.verticalGoal=undefined;
      if(forward?input.selectionEnd!==input.value.length:input.selectionStart!==0)return false;
    }
    event.preventDefault();event.stopPropagation();this.commit();
    let nextRow=row,nextColumn=column;
    if(vertical)nextRow+=forward?1:-1;
    else {
      nextColumn+=forward?1:-1;
      if(nextColumn<0){nextRow--;nextColumn=this.model.columns-1;}
      if(nextColumn>=this.model.columns){nextRow++;nextColumn=0;}
    }
    if(nextRow<0||nextRow>=this.model.rows.length)this.leave(forward,vertical,x);
    else this.activate(nextRow,nextColumn,{edge:forward?'start':'end',x});
    return true;
  }

  commit() {
    if(this.writing||this.rebuilding||this.destroyed)return;
    this.rebase();
    const record=this.cells[this.row]?.[this.column];if(!record)return;
    const composing=this.composing;this.composing=false;
    if(!this.view.state.readOnly) {
      const change=changeCell(this.model,this.row,this.column,record.input.value);
      if(!sameChange(this.view,change)) {
        this.writing=true;
        try {
          const cursor=change.from+encodeCell(record.input.value.slice(0,record.input.selectionStart)).length;
          this.view.dispatch({changes:change,selection:{anchor:cursor},userEvent:'input.table'});
        } finally {this.writing=false;}
      }
    }
    if(composing)window.DuckpadEditor.compositionEnd();
  }

  syncSelection() {
    if(this.composing||this.writing||this.rebuilding||this.destroyed)return;
    const record=this.cells[this.row]?.[this.column],cell=this.model.rows[this.row]?.cells[this.column];
    if(!record||!cell||document.activeElement!==record.input)return;
    const anchor=cell.from+encodeCell(record.input.value.slice(0,record.input.selectionStart)).length;
    const head=cell.from+encodeCell(record.input.value.slice(0,record.input.selectionEnd)).length;
    if(anchor<=cell.to&&head<=cell.to)this.view.dispatch({selection:{anchor,head}});
  }

  action(action) {
    this.commit();if(this.view.state.readOnly)return;
    const changes=changeTable(this.model,action,this.row,this.column);if(!changes.length)return;
    let row=this.row,column=this.column;
    if(action==='insertRow')row++;
    if(action==='insertColumn')column++;
    if(action==='deleteRow')row=Math.max(0,row-1);
    if(action==='deleteColumn')column=Math.max(0,column-1);
    this.view.dispatch({changes,userEvent:'input.table.structure'});
    this.activate(row,column);
  }

  key(event,row,column) {
    if(event.isComposing||this.composing||this.view.state.readOnly)return;
    if(/^Arrow(Left|Right|Up|Down)$/.test(event.key)){this.arrow(event,row,column);return;}
    this.verticalGoal=undefined;
    if((event.metaKey||event.ctrlKey)&&['z','s'].includes(event.key.toLowerCase())) {
      event.preventDefault();event.stopPropagation();this.commit();
      void window.DuckpadEditor.nativeCommand(event.key.toLowerCase()==='s'?'save':event.shiftKey?'redo':'undo');return;
    }
    if(event.key==='Escape') {
      event.preventDefault();this.commit();this.cells[row][column].input.blur();
      this.view.dispatch({selection:{anchor:Math.min(this.view.state.doc.length,this.model.to+1)}});this.view.focus();return;
    }
    if(event.key!=='Tab'&&event.key!=='Enter')return;
    event.preventDefault();event.stopPropagation();this.commit();
    let nextRow=row,nextColumn=column;
    if(event.key==='Tab') {
      nextColumn+=event.shiftKey?-1:1;
      if(nextColumn<0){nextRow--;nextColumn=this.model.columns-1;}
      if(nextColumn>=this.model.columns){nextRow++;nextColumn=0;}
    } else nextRow+=event.shiftKey?-1:1;
    if(nextRow<0) {this.view.dispatch({selection:{anchor:this.model.from}});this.view.focus();return;}
    if(nextRow>=this.model.rows.length) {this.action('insertRow');this.activate(nextRow,nextColumn);}
    else this.activate(nextRow,nextColumn);
  }

  destroy() {this.destroyed=true;document.removeEventListener('mousedown',this.outside);controllers.get(this.view)?.delete(this);}
}

export class EditableTable extends WidgetType {
  constructor(source,position,readOnly) {super();this.source=source;this.position=position;this.readOnly=readOnly;this.labels=window.DuckpadEditorLabels;}
  eq(other) {return this.source===other.source&&this.position===other.position&&this.readOnly===other.readOnly&&this.labels===other.labels;}
  toDOM(view) {
    const controller=new TableController(view,tableModel(this.source,this.position));
    controller.root.tableController=controller;return controller.root;
  }
  updateDOM(dom) {dom.tableController.sync(tableModel(this.source,this.position));return true;}
  destroy(dom) {dom.tableController.destroy();}
  ignoreEvent() {return true;}
}
