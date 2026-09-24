import DuckpadDomain
import Foundation

public enum IndentationDetector {
    public static let maximumProbeBytes = 65_536

    /// Conservative, bounded evidence: alignment spaces and mixed indentation
    /// must not replace a user's defaults on the strength of a single line.
    public static func detect(_ prefix: Data) -> LanguageIndentation? {
        let bytes = prefix.prefix(maximumProbeBytes)
        var tabs = 0, spaces = 0, previous = 0
        var deltas: [Int: Int] = [:]
        for line in bytes.split(separator: 10).prefix(1000) {
            let leading = line.prefix { $0 == 32 || $0 == 9 }
            guard leading.count < line.count, line.dropFirst(leading.count).contains(where: { $0 != 13 }) else { continue }
            if leading.first == 9 { tabs += 1; previous = 0; continue }
            guard !leading.contains(9) else { previous = 0; continue }
            let count = leading.count
            if count > 0 { spaces += 1 }
            let delta = abs(count - previous)
            if (2...8).contains(delta) { deltas[delta, default: 0] += 1 }
            previous = count
        }
        if tabs >= 2 && tabs >= spaces * 3 { return .init(useTabs: true) }
        guard spaces >= 2, spaces >= tabs * 3,
              let best = deltas.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first,
              best.value >= 2 else { return nil }
        return .init(width: best.key, useTabs: false)
    }
}
