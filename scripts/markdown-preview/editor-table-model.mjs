// Work in CodeMirror's LF/UTF-16 positions. Edits touch a cell or row rather
// than serializing the entire table, preserving unrelated Markdown spacing.
export function tableRow(text, from) {
  const boundaries=[];
  for(let index=0;index<text.length;index++)if(text[index]==='|') {
    let escapes=0;for(let at=index-1;at>=0&&text[at]==='\\';at--)escapes++;
    if(escapes%2===0)boundaries.push(index);
  }
  const edges=[-1,...boundaries,text.length],cells=[];
  for(let index=1;index<edges.length;index++) {
    let start=edges[index-1]+1,end=edges[index];
    if(index===1&&boundaries[0]===text.search(/\S/))continue;
    if(index===edges.length-1&&boundaries.at(-1)===text.trimEnd().length-1)continue;
    while(start<end&&/\s/.test(text[start]))start++;
    while(end>start&&/\s/.test(text[end-1]))end--;
    cells.push({from:from+start,to:from+end,source:text.slice(start,end)});
  }
  return {from,to:from+text.length,cells};
}

export function tableModel(source, from=0) {
  let position=from;
  const lines=source.split('\n').map(text=>{const row=tableRow(text,position);position+=text.length+1;return row;});
  const rows=[lines[0],...lines.slice(2)],columns=rows[0].cells.length;
  return {from,to:from+source.length,source,rows,columns,delimiter:lines[1],
    alignments:Array.from({length:columns},(_,column)=>{
      const delimiter=lines[1]?.cells[column]?.source||'';
      return delimiter.endsWith(':')?(delimiter.startsWith(':')?'center':'right'):'left';
    })};
}

export const displayCell=source=>source.replace(/(\\+)\|/g,(_match,slashes)=>'\\'.repeat(Math.floor(slashes.length/2))+'|');
export const encodeCell=value=>value.replace(/\r\n?|\n/g,' ').replace(/(\\*)\|/g,(_match,slashes)=>'\\'.repeat(slashes.length*2+1)+'|');
const rowSource=cells=>'| '+cells.join(' | ')+' |';

export function changeCell(model,row,column,value) {
  const record=model.rows[row],cell=record.cells[column],insert=encodeCell(value);
  if(cell)return {from:cell.from,to:cell.to,insert};
  const cells=Array.from({length:model.columns},(_,index)=>record.cells[index]?.source||'');
  cells[column]=insert;
  return {from:record.from,to:record.to,insert:rowSource(cells)};
}

export function changeTable(model,action,row,column) {
  if(action==='insertRow') {
    const at=row===0?model.delimiter.to:model.rows[row].to;
    return [{from:at,insert:'\n'+rowSource(Array(model.columns).fill(''))}];
  }
  if(action==='deleteRow') {
    if(row===0||!model.rows[row])return [];
    return [{from:model.rows[row].from-1,to:model.rows[row].to,insert:''}];
  }
  if(action==='deleteColumn'&&model.columns<=1)return [];
  if(action!=='insertColumn'&&action!=='deleteColumn')return [];
  return [model.rows[0],model.delimiter,...model.rows.slice(1)].map((record,index)=>{
    const cells=Array.from({length:Math.max(model.columns,record.cells.length)},(_,col)=>record.cells[col]?.source||'');
    if(action==='insertColumn')cells.splice(column+1,0,index===1?'---':'');
    else cells.splice(column,1);
    return {from:record.from,to:record.to,insert:rowSource(cells)};
  });
}
