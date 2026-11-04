import Foundation
import DuckpadDomain

/// Keeps token counts across edits; only a bounded neighbourhood is retokenized.
@MainActor public final class DocumentCompletionWordIndex {
    private struct Entry {
        var revision: UInt64
        var bytes: Data
        var counts: [String: Int]
    }
    private var entries: [BufferID: Entry] = [:]
    public init() {}
    public func retire(_ bufferID: BufferID) { entries.removeValue(forKey: bufferID) }

    public func terms(in capture: DocumentIntelligenceCapture) async -> [String] {
        if entries[capture.buffer.bufferID]?.revision != capture.buffer.revision {
            let task = Task.detached { Self.counts(capture.utf8, from: 0, to: capture.utf8.count, cancellable: true) }
            let counts = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
            guard !Task.isCancelled else { return [] }
            if entries.count >= 4 { entries.removeAll() }
            entries[capture.buffer.bufferID] = Entry(revision: capture.buffer.revision, bytes: capture.utf8, counts: counts)
        }
        let counts = entries[capture.buffer.bufferID]?.counts ?? [:]
        return counts.keys.sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0, default: 0] > counts[$1, default: 0] }
    }

    public func apply(_ edit: EditorIncrementalEdit) {
        guard var entry = entries.removeValue(forKey: edit.bufferID), entry.revision == edit.expectedRevision,
              edit.range.location >= 0, edit.range.length >= 0,
              edit.range.location <= entry.bytes.count,
              edit.range.length <= entry.bytes.count - edit.range.location else { return }
        let replacement = Data(edit.replacement.utf8)
        guard edit.range.length <= 16_384, replacement.count <= 16_384,
              entry.bytes.count - edit.range.length + replacement.count <= DocumentIntelligenceAnalyzer.maximumInputBytes else { return }
        let lower = max(0, edit.range.location - 1_024)
        let upper = min(entry.bytes.count, edit.range.location + edit.range.length + 1_024)
        for (word, count) in Self.counts(entry.bytes, from: lower, to: upper) {
            let remaining = (entry.counts[word] ?? 0) - count
            if remaining > 0 { entry.counts[word] = remaining } else { entry.counts.removeValue(forKey: word) }
        }
        entry.bytes.replaceSubrange(edit.range.location..<(edit.range.location + edit.range.length), with: replacement)
        for (word, count) in Self.counts(entry.bytes, from: lower, to: upper + replacement.count - edit.range.length) {
            entry.counts[word, default: 0] += count
        }
        entry.revision += 1
        entries[edit.bufferID] = entry
    }

    nonisolated private static func counts(_ bytes: Data, from start: Int, to end: Int, cancellable: Bool = false) -> [String: Int] {
        var lower = start, upper = end
        while lower < bytes.count && bytes[lower] & 0xC0 == 0x80 { lower += 1 }
        while upper > lower && upper < bytes.count && bytes[upper] & 0xC0 == 0x80 { upper -= 1 }
        guard lower <= upper, let text = String(data: bytes[lower..<upper], encoding: .utf8) else { return [:] }
        var result: [String: Int] = [:]
        var token = String.UnicodeScalarView(), tokenBytes = 0, tokenStart = 0, consumed = 0, overflow = false, countdown = 4096
        func finish(atEnd: Bool) {
            if !overflow, token.count >= 2, !(lower > 0 && tokenStart == 0), !(atEnd && upper < bytes.count) {
                result[String(token), default: 0] += 1
            }
            token.removeAll(keepingCapacity: true); tokenBytes = 0; overflow = false
        }
        for scalar in text.unicodeScalars {
            countdown -= 1
            if cancellable, countdown == 0 {
                guard !Task.isCancelled else { return [:] }; countdown = 4096
            }
            let width = scalar.utf8.count
            let isWord = scalar == "_" || CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
            if isWord {
                if tokenBytes == 0 && !overflow { tokenStart = consumed }
                if !overflow, tokenBytes + width <= 256 { token.append(scalar); tokenBytes += width }
                else { token.removeAll(keepingCapacity: true); overflow = true }
            } else { finish(atEnd: false) }
            consumed += width
        }
        finish(atEnd: true)
        return result
    }
}
