import test from 'node:test';
import assert from 'node:assert/strict';
import {EditorState} from '@codemirror/state';
import {RawDocument,normalized} from './editor-raw-document.mjs';

test('mixed line endings, emoji and Hangul survive unrelated edits',()=>{
  const source='# 한글 🦆\r\n\r\n**bold**\n\rfinal';
  const raw=new RawDocument(source,'\r\n');
  const state=EditorState.create({doc:normalized(source)});
  const tr=state.update({changes:{from:state.doc.length,insert:'\n끝'}});
  const result=raw.change(tr.changes,tr.state.selection.main);
  assert.equal(raw.raw,source+'\r\n끝');
  assert.equal(result.edits[0].location,new TextEncoder().encode(source).length);
  assert.equal(normalized(raw.raw),tr.state.doc.toString());
});
test('multiple changes retain every untouched original line ending',()=>{
  const source='one\r\ntwo\nthree\rfour';
  const raw=new RawDocument(source,'\r\n');
  const state=EditorState.create({doc:normalized(source)});
  const tr=state.update({changes:[{from:0,to:3,insert:'1'},{from:14,to:18,insert:'4'}]});
  const changes=raw.change(tr.changes,tr.state.selection.main);
  assert.equal(raw.raw,'1\r\ntwo\nthree\r4');
  assert.equal(changes.edits.length,2);
  assert.ok(changes.edits[0].location>changes.edits[1].location);
});
test('native UTF-8 deltas map back to CodeMirror UTF-16 coordinates',()=>{
  const raw=new RawDocument('🦆 한글\r\nbody');
  const from=new TextEncoder().encode('🦆 ').length;
  assert.deepEqual(raw.nativeChange(from,6,'문서'),{from:3,to:5,insert:'문서'});
  assert.equal(raw.raw,'🦆 문서\r\nbody');
  assert.equal(raw.positionAtUTF8(new TextEncoder().encode('🦆 문서\r\n').length),6);
});

// Independent slow model: materialize each UTF-8 segment as the original
// implementation did. Kept in the test itself, with no build artifact imports.
const utf8 = new TextEncoder();
function referenceCoordinates(source, positions) {
  const result = new Map();
  let raw = 0, logical = 0;
  for (const position of [...new Set(positions)].sort((a, b) => a - b)) {
    while (raw < source.length && logical < position) {
      const width = source.codePointAt(raw) > 0xffff ? 2 : 1;
      if (source[raw] === '\r' && source[raw + 1] === '\n') { raw += 2; logical++; }
      else { raw += width; logical += width; }
    }
    if (position < 0 || logical !== position) throw new RangeError();
    result.set(position, {raw, utf8: utf8.encode(source.slice(0, raw)).length});
  }
  return result;
}
function referenceSelection(source, selection) {
  const ranges = selection.ranges || [selection];
  const points = referenceCoordinates(source, ranges.flatMap(range => [range.anchor, range.head]));
  const values = ranges.map(range => ({anchor: points.get(range.anchor).utf8, caret: points.get(range.head).utf8}));
  return selection.ranges ? {...values[selection.mainIndex], ranges: values, mainIndex: selection.mainIndex} : values[0];
}
function referenceChange(source, lineEnding, changes, selection) {
  const edits = []; let raw = source;
  changes.iterChanges((from, to, _a, _b, inserted) => {
    const points = referenceCoordinates(source, [from, to]), first = points.get(from), last = points.get(to);
    edits.push({location: first.utf8, length: last.utf8 - first.utf8, deleted: source.slice(first.raw, last.raw), replacement: inserted.toString().replace(/\n/g, lineEnding), first: first.raw, last: last.raw});
  });
  for (const edit of edits.reverse()) {
    const prefix = raw.slice(0, edit.first), suffix = raw.slice(edit.last);
    if (prefix.endsWith('\r') && suffix.startsWith('\n') && !edit.replacement) edit.replacement = '\n';
    else {
      if (prefix.endsWith('\r') && edit.replacement.startsWith('\n')) edit.replacement = '\r' + edit.replacement;
      if (suffix.startsWith('\n') && edit.replacement.endsWith('\r')) edit.replacement += '\n';
    }
    raw = prefix + edit.replacement + suffix;
  }
  return {raw, result: {edits: edits.map(({first,last,...edit})=>edit), selection: referenceSelection(raw, selection)}};
}
function referenceNative(source, location, length, replacement) {
  const bytes = utf8.encode(source), decoder = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true});
  const prefix = decoder.decode(bytes.subarray(0, location)), removed = decoder.decode(bytes.subarray(location, location + length));
  const from = normalized(prefix).length;
  return {
    raw: prefix + replacement + decoder.decode(bytes.subarray(location + length)),
    result: {from, to: from + normalized(removed).length, insert: normalized(replacement)},
  };
}
function boundaries(text, bytes = false) {
  const result = [0]; let offset = 0;
  for (const point of text) { offset += bytes ? utf8.encode(point).length : point.length; result.push(offset); }
  return result;
}
function randomGenerator(seed) {
  return limit => { seed = Math.imul(seed, 1664525) + 1013904223 | 0; return (seed >>> 0) % limit; };
}
const samplePieces = ['abc', ' ', '한글', '🦆', 'e\u0301', '\r\n', '\r', '\n', '| **x** | `code` |'];
function randomSource(random, count) { return Array.from({length: count}, () => samplePieces[random(samplePieces.length)]).join(''); }
function checkCoordinates(raw, random) {
  const logical = normalized(raw.raw), positions = boundaries(logical);
  const selected = [0, logical.length, ...Array.from({length: 12}, () => positions[random(positions.length)])];
  assert.deepEqual(raw.coordinates(selected), referenceCoordinates(raw.raw, selected));
  const bytes = boundaries(raw.raw, true), offsets = [0, bytes[bytes.length - 1], ...Array.from({length: 12}, () => bytes[random(bytes.length)])];
  const encoded = utf8.encode(raw.raw), decoder = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true});
  const expected = new Map([...new Set(offsets)].sort((a, b) => a - b).map(offset => [offset, normalized(decoder.decode(encoded.subarray(0, offset))).length]));
  assert.deepEqual(raw.positionsAtUTF8(offsets), expected);
}

test('indexed coordinates match the byte model after randomized multi-cursor edits', () => {
  const random = randomGenerator(0x17da6), replacements = ['', 'x', '한🦆', '\n끝\n', '**bold**'];
  for (const lineEnding of ['\n', '\r\n', '\r']) {
    const raw = new RawDocument(randomSource(random, 1500), lineEnding);
    let state = EditorState.create({doc: normalized(raw.raw)});
    for (let iteration = 0; iteration < 180; iteration++) {
      const positions = boundaries(state.doc.toString()), changeCount = 1 + random(3), changes = [];
      const slots = [...new Set(Array.from({length: changeCount * 2}, () => random(positions.length)))].sort((a, b) => a - b);
      for (let i = 0; i + 1 < slots.length; i += 2) {
        const from = positions[slots[i]], to = positions[Math.min(slots[i + 1], slots[i] + random(8))];
        changes.push({from, to, insert: replacements[random(replacements.length)]});
      }
      const transaction = state.update({changes});
      const preview = referenceChange(raw.raw, lineEnding, transaction.changes, {anchor: 0, head: 0});
      const after = transaction.state.doc.toString(), targets = boundaries(after);
      const selection = {ranges: [{anchor: targets[random(targets.length)], head: targets[random(targets.length)]}, {anchor: after.length, head: after.length}], mainIndex: iteration % 2};
      const before = raw.raw, expected = referenceChange(before, lineEnding, transaction.changes, selection);
      assert.deepEqual(raw.change(transaction.changes, selection), expected.result);
      assert.equal(raw.raw, expected.raw);
      assert.equal(normalized(raw.raw), after);
      // Native mirror applies descending deltas to precisely the same bytes.
      const mirror = new RawDocument(before, lineEnding);
      for (const edit of expected.result.edits) mirror.nativeChange(edit.location, edit.length, edit.replacement);
      assert.equal(mirror.raw, raw.raw);
      checkCoordinates(raw, random);
      assert.equal(normalized(raw.raw), transaction.state.doc.toString());
      state = transaction.state;
    }
  }
});

test('native deltas match the decoder model across CRLF and checkpoint boundaries', () => {
  const random = randomGenerator(0xeed), replacements = ['', '\r', '\n', '\r\n', '한🦆', '\n\r끝'];
  const raw = new RawDocument('a'.repeat(1023) + '\r\n🦆' + randomSource(random, 1500));
  for (let iteration = 0; iteration < 700; iteration++) {
    const offsets = boundaries(raw.raw, true), first = random(offsets.length), last = Math.min(offsets.length - 1, first + random(7));
    const location = offsets[first], length = offsets[last] - location, replacement = replacements[random(replacements.length)];
    const expected = referenceNative(raw.raw, location, length, replacement);
    const before = normalized(raw.raw), change = raw.nativeChange(location, length, replacement);
    assert.equal(before.slice(0, change.from) + change.insert + before.slice(change.to), normalized(expected.raw));
    assert.equal(raw.raw, expected.raw);
    checkCoordinates(raw, random);
  }
});

test('native CRLF split and join edits preserve exact bytes and the normalized mirror', () => {
  for (const prefix of ['', 'a'.repeat(1023), '🦆한'.repeat(700)]) {
    for (const [relative, length] of [[0, 0], [1, 0], [1, 1], [0, 1], [0, 2], [2, 0]]) {
      for (const replacement of ['', '\r', '\n', '🦆']) {
        const source = prefix + '\r\nend', location = utf8.encode(prefix).length + relative;
        const expected = referenceNative(source, location, length, replacement), raw = new RawDocument(source);
        const before = normalized(raw.raw), change = raw.nativeChange(location, length, replacement);
        assert.equal(before.slice(0, change.from) + change.insert + before.slice(change.to), normalized(expected.raw));
        assert.equal(raw.raw, expected.raw);
        checkCoordinates(raw, randomGenerator(23));
      }
    }
  }
});

test('invalid Unicode boundaries reject without changing document or index', () => {
  const source = 'a'.repeat(1023) + '🦆한\r\nend', raw = new RawDocument(source);
  for (const position of [-1, 1024, normalized(source).length + 1]) assert.throws(() => raw.rawOffset(position), RangeError);
  for (const offset of [-1, 1024, 1025, 1026, 1028, 1029, utf8.encode(source).length + 1]) assert.throws(() => raw.positionAtUTF8(offset), RangeError);
  for (const [location, length] of [[1024, 0], [1023, 1], [1027, 1]]) assert.throws(() => raw.nativeChange(location, length, 'x'), TypeError);
  for (const [location, length] of [[-1, 0], [0, -1], [utf8.encode(source).length, 1]]) assert.throws(() => raw.nativeChange(location, length, 'x'), RangeError);
  assert.equal(raw.raw, source);
  checkCoordinates(raw, randomGenerator(9));
});

test('unpaired surrogates retain TextEncoder replacement and newly joined pairs', () => {
  for (const source of ['a\ud800x\udc00', 'a'.repeat(1023) + '\ud800x\udc00', '\ud800', '\udc00']) {
    const raw = new RawDocument(source), expected = referenceNative(source, 0, 0, '\r');
    assert.deepEqual(raw.nativeChange(0, 0, '\r'), expected.result);
    assert.equal(raw.raw, expected.raw);
    checkCoordinates(raw, randomGenerator(7));
  }
  const raw = new RawDocument('a'.repeat(1023) + '\ud800x');
  raw.nativeChange(utf8.encode('a'.repeat(1023) + '\ud800').length, 1, '\udc00');
  // The old UTF-8 roundtrip replaces the preexisting high surrogate first.
  assert.equal(raw.raw, 'a'.repeat(1023) + '\ufffd\udc00');
  const expected = referenceNative(raw.raw, 0, 0, '');
  assert.deepEqual(raw.nativeChange(0, 0, ''), expected.result);
  assert.equal(raw.raw, expected.raw);
});

test('EOF lookup and small edits scan bounded intervals on long lines', () => {
  const raw = new RawDocument('a'.repeat(276000)), originalPointAt = String.prototype.codePointAt, originalEncode = TextEncoder.prototype.encode;
  let scanned = 0, encoded = 0;
  String.prototype.codePointAt = function (...args) { scanned++; return originalPointAt.apply(this, args); };
  TextEncoder.prototype.encode = function (text) { encoded += text.length; return originalEncode.call(this, text); };
  try {
    for (let i = 0; i < 40; i++) {
      scanned = 0;
      const position = raw.raw.length - 3;
      assert.equal(raw.utf8Offset(position), position);
      assert.equal(raw.positionAtUTF8(position), position);
      raw.nativeChange(position, 1, '한');
      raw.change({iterChanges: apply => apply(position, position + 1, position, position + 1, {toString: () => 'x'})}, {anchor: position + 1, head: position + 1});
      assert.ok(scanned < 8192, `local operation scanned ${scanned} code points`);
    }
    assert.equal(encoded, 0, 'valid native deltas must not encode the entire document');
  } finally { String.prototype.codePointAt = originalPointAt; TextEncoder.prototype.encode = originalEncode; }
});


test('literal U+FEFF survives native edits at every byte boundary and raw replacement', () => {
  for (const source of ['\ufeffa한\r\nend', 'a\ufeff한\r\nend', 'a'.repeat(1023) + '\ufeffx']) {
    const offsets = boundaries(source, true);
    for (let first = 0; first < offsets.length; first += Math.max(1, Math.floor(offsets.length / 15))) {
      for (const last of [first, Math.min(offsets.length - 1, first + 1), offsets.length - 1]) {
        const raw = new RawDocument('old'); raw.raw = source;
        const location = offsets[first], length = offsets[last] - location, expected = referenceNative(source, location, length, '끝');
        const before = normalized(raw.raw), change = raw.nativeChange(location, length, '끝');
        assert.equal(before.slice(0, change.from) + change.insert + before.slice(change.to), normalized(expected.raw));
        assert.equal(raw.raw, expected.raw);
        checkCoordinates(raw, randomGenerator(11));
      }
    }
  }
});

test('editor splices coalesce surrogate pairs at either side of a checkpoint', () => {
  for (const size of [1022, 1023, 1024, 2047]) {
    for (const joinAfter of [false, true]) {
      const prefix = 'a'.repeat(size), source = prefix + (joinAfter ? '\ud800x' : '\udc00x');
      const position = size + (joinAfter ? 1 : 0), insertion = joinAfter ? '\udc00' : '\ud800';
      const changes = {iterChanges: apply => apply(position, position, position, position + 1, {toString: () => insertion})};
      const selection = {anchor: size + 2, head: size + 2};
      const expected = referenceChange(source, '\n', changes, selection), raw = new RawDocument(source);
      assert.deepEqual(raw.change(changes, selection), expected.result);
      assert.equal(raw.raw, prefix + '𐀀x');
      checkCoordinates(raw, randomGenerator(31));
      const location = utf8.encode(prefix + '𐀀').length;
      assert.deepEqual(raw.nativeChange(location, 1, '끝'), {from: size + 2, to: size + 3, insert: '끝'});
      assert.equal(raw.raw, prefix + '𐀀끝');
    }
  }
});
