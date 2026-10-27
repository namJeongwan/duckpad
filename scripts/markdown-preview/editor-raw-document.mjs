// CodeMirror uses LF/UTF-16 coordinates. Duckpad stores exact UTF-8 bytes,
// including mixed CRLF/LF/CR. Keep those representations separate.
export const normalized = text => text.replace(/\r\n?|\n/g, '\n');
const encoder = new TextEncoder();
const checkpointStride = 1024;
const byteWidth = point => point < 128 ? 1 : point < 2048 ? 2 : point < 65536 ? 3 : 4;

// Checkpoints never split a surrogate pair or CRLF. Each lookup scans at most
// one checkpoint interval, including documents made of a single long line.
function checkpoints(text, start, end) {
  const result = [start];
  let {raw, logical, utf8, invalid} = start, previous = raw;
  while (raw < end) {
    const point = text.codePointAt(raw), width = point > 0xffff ? 2 : 1;
    if (point === 13 && text[raw + 1] === '\n') { raw += 2; logical++; utf8 += 2; }
    else {
      raw += width; logical += width; utf8 += byteWidth(point);
      if (point >= 0xd800 && point <= 0xdfff) invalid++;
    }
    if (raw - previous >= checkpointStride || raw === end) {
      result.push({raw, logical, utf8, invalid}); previous = raw;
    }
  }
  return result;
}
function preceding(points, key, value) {
  let first = 0, last = points.length;
  while (first < last) {
    const middle = (first + last) >>> 1;
    if (points[middle][key] <= value) first = middle + 1;
    else last = middle;
  }
  return Math.max(0, first - 1);
}

export class RawDocument {
  constructor(raw, lineEnding = '\n') { this.raw = raw; this.lineEnding = lineEnding; }
  get raw() { return this._raw; }
  set raw(value) {
    this._raw = value;
    this._checkpoints = checkpoints(value, {raw: 0, logical: 0, utf8: 0, invalid: 0}, value.length);
  }
  coordinates(positions) {
    const result = new Map(), points = this._checkpoints, end = points[points.length - 1];
    for (const position of [...new Set(positions)].sort((a, b) => a - b)) {
      if (!Number.isInteger(position) || position < 0 || position > end.logical) throw new RangeError('Invalid CodeMirror position');
      let {raw, logical, utf8} = points[preceding(points, 'logical', position)];
      while (logical < position) {
        const point = this.raw.codePointAt(raw), width = point > 0xffff ? 2 : 1;
        if (point === 13 && this.raw[raw + 1] === '\n') { raw += 2; utf8 += 2; logical++; }
        else { raw += width; logical += width; utf8 += byteWidth(point); }
      }
      if (logical !== position) throw new RangeError('Invalid CodeMirror position');
      result.set(position, {raw, utf8});
    }
    return result;
  }
  rawOffset(position) { return this.coordinates([position]).get(position).raw; }
  utf8Offset(position) { return this.coordinates([position]).get(position).utf8; }
  selection(selection) {
    const ranges = selection.ranges || [selection], coordinates = this.coordinates(ranges.flatMap(range => [range.anchor, range.head]));
    const values = ranges.map(range => ({anchor: coordinates.get(range.anchor).utf8, caret: coordinates.get(range.head).utf8}));
    return selection.ranges ? {...values[selection.mainIndex], ranges: values, mainIndex: selection.mainIndex} : values[0];
  }
  change(changes, selection) {
    const edits = [], pending = [];
    changes.iterChanges((from, to, _newFrom, _newTo, inserted) => pending.push({from, to, inserted}));
    const coordinates = this.coordinates(pending.flatMap(change => [change.from, change.to]));
    for (const change of pending) {
      const first = coordinates.get(change.from), last = coordinates.get(change.to), replacement = change.inserted.toString().replace(/\n/g, this.lineEnding);
      edits.push({location: first.utf8, length: last.utf8 - first.utf8, deleted: this.raw.slice(first.raw, last.raw), replacement, first: first.raw, last: last.raw});
    }
    // Right-to-left application keeps every original edit coordinate valid.
    // Reindex only the checkpoints enclosing each splice, including its edges
    // so newly joined CRLF and surrogate pairs are counted correctly.
    for (let i = edits.length - 1; i >= 0; i--) {
      const edit = edits[i], beforeCR = this.raw[edit.first - 1] === '\r', afterLF = this.raw[edit.last] === '\n';
      // Preserve the logical newline count when a splice joins existing CR/LF
      // to a newly serialized newline (or to each other after deletion).
      if (!edit.replacement && beforeCR && afterLF) edit.replacement = '\n';
      else {
        if (beforeCR && edit.replacement.startsWith('\n')) edit.replacement = '\r' + edit.replacement;
        if (afterLF && edit.replacement.endsWith('\r')) edit.replacement += '\n';
      }
      this._replace(edit.first, edit.last, edit.replacement);
    }
    return {edits: edits.map(({first, last, ...edit}) => edit).reverse(), selection: this.selection(selection)};
  }
  _replace(from, to, replacement) {
    const points = this._checkpoints;
    let first = preceding(points, 'raw', from);
    if (first > 0 && points[first].raw === from) first--;
    const last = Math.min(points.length - 1, preceding(points, 'raw', to) + 1);
    const oldEnd = points[last], rawDelta = replacement.length - (to - from);
    this._raw = this.raw.slice(0, from) + replacement + this.raw.slice(to);
    const rebuilt = checkpoints(this.raw, points[first], oldEnd.raw + rawDelta), newEnd = rebuilt[rebuilt.length - 1];
    const logicalDelta = newEnd.logical - oldEnd.logical, utf8Delta = newEnd.utf8 - oldEnd.utf8, invalidDelta = newEnd.invalid - oldEnd.invalid;
    const result = points.slice(0, first);
    for (const point of rebuilt) result.push(point);
    for (let i = last + 1; i < points.length; i++) {
      const point = points[i];
      result.push({raw: point.raw + rawDelta, logical: point.logical + logicalDelta, utf8: point.utf8 + utf8Delta, invalid: point.invalid + invalidDelta});
    }
    this._checkpoints = result;
  }
  _coordinateAtUTF8(offset) {
    const points = this._checkpoints, end = points[points.length - 1];
    if (!Number.isInteger(offset) || offset < 0 || offset > end.utf8) throw new RangeError('Invalid UTF-8 position');
    let {raw, logical, utf8} = points[preceding(points, 'utf8', offset)], previousCR = false;
    while (utf8 < offset) {
      const point = this.raw.codePointAt(raw), width = point > 0xffff ? 2 : 1;
      raw += width; utf8 += byteWidth(point);
      if (!(point === 10 && previousCR)) logical += width;
      previousCR = point === 13;
    }
    if (utf8 !== offset) throw new RangeError('Invalid UTF-8 position');
    return {raw, logical};
  }
  nativeChange(location, length, replacement) {
    const end = this._checkpoints[this._checkpoints.length - 1];
    if (!Number.isInteger(location) || !Number.isInteger(length) || location < 0 || length < 0 || location + length > end.utf8) throw new RangeError('Invalid native range');
    // Malformed UTF-16 retains the decoder fallback. Literal U+FEFF belongs
    // to document content; it is never stripped as a segment-leading BOM.
    if (end.invalid) return this._nativeChangeDecoded(location, length, replacement);
    let first, last;
    try { first = this._coordinateAtUTF8(location); last = this._coordinateAtUTF8(location + length); }
    catch { throw new TypeError('The encoded data was not valid for encoding utf-8'); }
    // Include neighboring CR/LF in the logical replacement: native edits can
    // split or join a pair even though only the requested exact bytes change.
    const start = first.raw > 0 && this.raw[first.raw - 1] === '\r' ? first.raw - 1 : first.raw;
    const endRaw = this.raw[last.raw] === '\n' ? last.raw + 1 : last.raw;
    const from = first.logical - (first.raw - start);
    const to = from + normalized(this.raw.slice(start, endRaw)).length;
    const insert = normalized(this.raw.slice(start, first.raw) + replacement + this.raw.slice(last.raw, endRaw));
    this._replace(first.raw, last.raw, replacement);
    return {from, to, insert};
  }
  _nativeChangeDecoded(location, length, replacement) {
    const bytes = encoder.encode(this.raw), decoder = new TextDecoder('utf-8', {fatal: true, ignoreBOM: true});
    const prefix = decoder.decode(bytes.subarray(0, location)), deleted = decoder.decode(bytes.subarray(location, location + length));
    this.raw = prefix + replacement + decoder.decode(bytes.subarray(location + length));
    const from = normalized(prefix).length;
    return {from, to: from + normalized(deleted).length, insert: normalized(replacement)};
  }
  positionAtUTF8(offset) { return this._coordinateAtUTF8(offset).logical; }
  positionsAtUTF8(offsets) {
    return new Map([...new Set(offsets)].sort((a, b) => a - b).map(offset => [offset, this._coordinateAtUTF8(offset).logical]));
  }
}
