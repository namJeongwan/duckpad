import test from 'node:test';
import assert from 'node:assert/strict';
import {tableModel,changeCell,changeTable,displayCell,encodeCell} from './editor-table-model.mjs';
const apply=(text,changes)=>changes.toSorted((a,b)=>b.from-a.from).reduce((text,change)=>text.slice(0,change.from)+change.insert+text.slice(change.to??change.from),text);

test('cell ranges preserve alignment, spacing, escaped pipes and Unicode',()=>{
  const source='|  A  | B |\n| :--- | ---: |\n| 한글 🦆 | a \\| b |';
  const model=tableModel(source);
  assert.deepEqual(model.alignments,['left','right']);
  assert.equal(model.rows[1].cells.length,2);
  const changed=apply(source,[changeCell(model,1,0,'새 값 | 셀')]);
  assert.equal(changed,'|  A  | B |\n| :--- | ---: |\n| 새 값 \\| 셀 | a \\| b |');
  assert.equal(displayCell(encodeCell('a | b \\| c')),'a | b \\| c');
});

test('empty cells and rows without outer pipes retain valid boundaries',()=>{
  const source='A | B\n--- | ---\none |';
  const model=tableModel(source);
  const changed=apply(source,[changeCell(model,1,1,'two')]);
  assert.equal(tableModel(changed).rows[1].cells[1].source,'two');
  assert.equal(apply('| | |',[changeCell(tableModel('| | |\n| --- | --- |'),0,0,'한글')]),'| 한글| |');
});

test('row and column actions are reversible and preserve delimiter alignment',()=>{
  let source='| A | B |\n| :--- | ---: |\n| one | two |';
  const original=source;
  source=apply(source,changeTable(tableModel(source),'insertRow',1,0));
  assert.equal(tableModel(source).rows.length,3);
  source=apply(source,changeTable(tableModel(source),'insertColumn',2,0));
  assert.deepEqual(tableModel(source).alignments,['left','left','right']);
  source=apply(source,changeTable(tableModel(source),'deleteColumn',2,1));
  source=apply(source,changeTable(tableModel(source),'deleteRow',2,0));
  assert.equal(source,original);
  assert.deepEqual(changeTable(tableModel('| A |\n| --- |'),'deleteColumn',0,0),[]);
  assert.deepEqual(changeTable(tableModel(original),'deleteRow',0,0),[]);
});
