import DuckpadApplication

public struct AlignedLineDiff: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case unchanged
        case inserted
        case deleted
        case replaced
    }

    public struct LineReference: Equatable, Sendable {
        public let number: Int
        public let utf8Range: Range<Int>

        public init(number: Int, utf8Range: Range<Int>) {
            self.number = number
            self.utf8Range = utf8Range
        }
    }

    public struct Row: Equatable, Sendable {
        public let left: LineReference?
        public let right: LineReference?
        public let kind: Kind

        public init(left: LineReference?, right: LineReference?, kind: Kind) {
            self.left = left
            self.right = right
            self.kind = kind
        }
    }

    public let rows: [Row]
    public let usedFallback: Bool

    public init(rows: [Row], usedFallback: Bool) {
        self.rows = rows
        self.usedFallback = usedFallback
    }

    public static func build(
        left: String,
        right: String,
        limits: OpenDocumentComparison.Limits = .default,
        isCancelled: @Sendable () -> Bool = {
            withUnsafeCurrentTask { $0?.isCancelled ?? false }
        }
    ) throws(OpenDocumentComparison.Error) -> AlignedLineDiff {
        let leftSource = try LineSource(
            text: left,
            side: .left,
            maximumUTF8Bytes: limits.maximumUTF8BytesPerSide,
            maximumLines: limits.maximumLinesPerSide,
            isCancelled: isCancelled
        )
        let rightSource = try LineSource(
            text: right,
            side: .right,
            maximumUTF8Bytes: limits.maximumUTF8BytesPerSide,
            maximumLines: limits.maximumLinesPerSide,
            isCancelled: isCancelled
        )
        try checkCancellation(isCancelled)

        var prefixCount = 0
        let sharedCount = min(leftSource.lines.count, rightSource.lines.count)
        while prefixCount < sharedCount {
            try checkCancellation(isCancelled)
            guard try leftSource.matches(
                prefixCount,
                in: rightSource,
                at: prefixCount,
                isCancelled: isCancelled
            ) else { break }
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < sharedCount - prefixCount {
            let leftIndex = leftSource.lines.count - suffixCount - 1
            let rightIndex = rightSource.lines.count - suffixCount - 1
            try checkCancellation(isCancelled)
            guard try leftSource.matches(
                leftIndex,
                in: rightSource,
                at: rightIndex,
                isCancelled: isCancelled
            ) else { break }
            suffixCount += 1
        }

        let leftMiddle = prefixCount..<(leftSource.lines.count - suffixCount)
        let rightMiddle = prefixCount..<(rightSource.lines.count - suffixCount)
        let fixedRowCount = prefixCount + suffixCount
        guard fixedRowCount <= limits.maximumAlignedRows else {
            throw .complexityExceeded(maximumRows: limits.maximumAlignedRows)
        }
        var prefix: [Row] = []
        prefix.reserveCapacity(prefixCount)
        for index in 0..<prefixCount {
            if index.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
            prefix.append(Row(
                left: leftSource.reference(at: index),
                right: rightSource.reference(at: index),
                kind: .unchanged
            ))
        }
        var suffix: [Row] = []
        suffix.reserveCapacity(suffixCount)
        for offset in 0..<suffixCount {
            if offset.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
            let leftIndex = leftSource.lines.count - suffixCount + offset
            let rightIndex = rightSource.lines.count - suffixCount + offset
            suffix.append(Row(
                left: leftSource.reference(at: leftIndex),
                right: rightSource.reference(at: rightIndex),
                kind: .unchanged
            ))
        }

        guard !leftMiddle.isEmpty || !rightMiddle.isEmpty else {
            return try checked(rows: prefix + suffix, usedFallback: false, limits: limits)
        }

        if let edits = try shortestEdits(
            left: leftSource,
            leftRange: leftMiddle,
            right: rightSource,
            rightRange: rightMiddle,
            maximumSteps: limits.maximumDiffSteps,
            isCancelled: isCancelled
        ) {
            let exactMiddle = try alignedRows(
                edits: edits,
                left: leftSource,
                right: rightSource,
                maximumRows: limits.maximumAlignedRows - fixedRowCount,
                isCancelled: isCancelled
            )
            if let exactMiddle {
                try checkCancellation(isCancelled)
                let exactRows = prefix + exactMiddle + suffix
                return AlignedLineDiff(rows: exactRows, usedFallback: false)
            }
        }

        let fallbackRowCount = fixedRowCount + max(leftMiddle.count, rightMiddle.count)
        guard fallbackRowCount <= limits.maximumAlignedRows else {
            throw .complexityExceeded(maximumRows: limits.maximumAlignedRows)
        }
        var fallbackRows = prefix
        fallbackRows.reserveCapacity(fallbackRowCount)
        _ = try appendChangedRows(
            deleted: leftMiddle,
            inserted: rightMiddle,
            left: leftSource,
            right: rightSource,
            maximumRows: limits.maximumAlignedRows - suffixCount,
            isCancelled: isCancelled,
            to: &fallbackRows
        )
        try checkCancellation(isCancelled)
        fallbackRows.append(contentsOf: suffix)
        return AlignedLineDiff(rows: fallbackRows, usedFallback: true)
    }

    private static func checked(
        rows: [Row],
        usedFallback: Bool,
        limits: OpenDocumentComparison.Limits
    ) throws(OpenDocumentComparison.Error) -> AlignedLineDiff {
        guard rows.count <= limits.maximumAlignedRows else {
            throw .complexityExceeded(maximumRows: limits.maximumAlignedRows)
        }
        return AlignedLineDiff(rows: rows, usedFallback: usedFallback)
    }

    private static func checkCancellation(
        _ isCancelled: @Sendable () -> Bool
    ) throws(OpenDocumentComparison.Error) {
        if isCancelled() { throw .cancelled }
    }
}

private extension AlignedLineDiff {
    struct LineToken {
        let range: Range<Int>
        let hash: UInt64
    }

    struct LineSource {
        let bytes: [UInt8]
        let lines: [LineToken]

        init(
            text: String,
            side: OpenDocumentComparison.Side,
            maximumUTF8Bytes: Int,
            maximumLines: Int,
            isCancelled: @Sendable () -> Bool
        ) throws(OpenDocumentComparison.Error) {
            let byteCount = text.utf8.count
            guard byteCount <= maximumUTF8Bytes else {
                throw .inputTooLarge(side: side, byteCount: byteCount, maximum: maximumUTF8Bytes)
            }
            var collectedBytes: [UInt8] = []
            collectedBytes.reserveCapacity(byteCount)
            var lines: [LineToken] = []
            lines.reserveCapacity(min(maximumLines, 1_024))
            var start = 0
            var hash: UInt64 = 14_695_981_039_346_656_037
            var previousWasCarriageReturn = false
            for (index, byte) in text.utf8.enumerated() {
                if index.isMultiple(of: 4_096) { try AlignedLineDiff.checkCancellation(isCancelled) }
                collectedBytes.append(byte)
                if previousWasCarriageReturn {
                    previousWasCarriageReturn = false
                    if byte == 0x0A {
                        start = index + 1
                        continue
                    }
                }
                if byte != 0x0D, byte != 0x0A {
                    hash ^= UInt64(byte)
                    hash &*= 1_099_511_628_211
                    continue
                }
                lines.append(LineToken(range: start..<index, hash: hash))
                if lines.count > maximumLines {
                    throw .tooManyLines(side: side, lineCount: lines.count, maximum: maximumLines)
                }
                start = index + 1
                hash = 14_695_981_039_346_656_037
                previousWasCarriageReturn = byte == 0x0D
            }
            lines.append(LineToken(range: start..<collectedBytes.count, hash: hash))
            guard lines.count <= maximumLines else {
                throw .tooManyLines(side: side, lineCount: lines.count, maximum: maximumLines)
            }
            bytes = collectedBytes
            self.lines = lines
        }

        func reference(at index: Int) -> LineReference {
            LineReference(number: index + 1, utf8Range: lines[index].range)
        }

        func matches(
            _ index: Int,
            in other: LineSource,
            at otherIndex: Int,
            isCancelled: @Sendable () -> Bool
        ) throws(OpenDocumentComparison.Error) -> Bool {
            let lhs = lines[index]
            let rhs = other.lines[otherIndex]
            guard lhs.hash == rhs.hash, lhs.range.count == rhs.range.count else { return false }
            for offset in 0..<lhs.range.count {
                if offset.isMultiple(of: 4_096) { try AlignedLineDiff.checkCancellation(isCancelled) }
                if bytes[lhs.range.lowerBound + offset] != other.bytes[rhs.range.lowerBound + offset] {
                    return false
                }
            }
            return true
        }
    }

    enum Edit {
        case equal(left: Int, right: Int)
        case delete(left: Int)
        case insert(right: Int)
    }

    static func shortestEdits(
        left: LineSource,
        leftRange: Range<Int>,
        right: LineSource,
        rightRange: Range<Int>,
        maximumSteps: Int,
        isCancelled: @Sendable () -> Bool
    ) throws(OpenDocumentComparison.Error) -> [Edit]? {
        let leftCount = leftRange.count
        let rightCount = rightRange.count
        var trace: [[Int]] = []
        var previous: [Int] = []
        var steps = 0

        for distance in 0...(leftCount + rightCount) {
            try checkCancellation(isCancelled)
            var frontier: [Int] = []
            frontier.reserveCapacity(distance + 1)
            for diagonal in stride(from: -distance, through: distance, by: 2) {
                guard steps < maximumSteps else { return nil }
                steps += 1
                let startX: Int
                if distance == 0 {
                    startX = 0
                } else if diagonal == -distance {
                    startX = previousValue(previous, distance: distance - 1, diagonal: diagonal + 1)
                } else if diagonal == distance {
                    startX = previousValue(previous, distance: distance - 1, diagonal: diagonal - 1) + 1
                } else {
                    let deletion = previousValue(previous, distance: distance - 1, diagonal: diagonal - 1) + 1
                    let insertion = previousValue(previous, distance: distance - 1, diagonal: diagonal + 1)
                    startX = deletion > insertion ? deletion : insertion
                }

                var x = startX
                var y = x - diagonal
                while x < leftCount, y < rightCount {
                    guard steps < maximumSteps else { return nil }
                    steps += 1
                    guard try left.matches(
                        leftRange.lowerBound + x,
                        in: right,
                        at: rightRange.lowerBound + y,
                        isCancelled: isCancelled
                    ) else {
                        break
                    }
                    x += 1
                    y += 1
                }
                frontier.append(x)
                if x == leftCount, y == rightCount {
                    trace.append(frontier)
                    return try reconstruct(
                        trace: trace,
                        leftRange: leftRange,
                        rightRange: rightRange,
                        isCancelled: isCancelled
                    )
                }
            }
            trace.append(frontier)
            previous = frontier
        }
        return nil
    }

    static func previousValue(_ frontier: [Int], distance: Int, diagonal: Int) -> Int {
        guard distance >= 0,
              diagonal >= -distance,
              diagonal <= distance,
              (diagonal + distance).isMultiple(of: 2) else { return 0 }
        return frontier[(diagonal + distance) / 2]
    }

    static func reconstruct(
        trace: [[Int]],
        leftRange: Range<Int>,
        rightRange: Range<Int>,
        isCancelled: @Sendable () -> Bool
    ) throws(OpenDocumentComparison.Error) -> [Edit] {
        try checkCancellation(isCancelled)
        var x = leftRange.count
        var y = rightRange.count
        var reversed: [Edit] = []
        var backtrackSteps = 0

        if trace.count > 1 {
            for distance in stride(from: trace.count - 1, through: 1, by: -1) {
                if backtrackSteps.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
                backtrackSteps += 1
                let diagonal = x - y
                let previous = trace[distance - 1]
                let previousDiagonal: Int
                if diagonal == -distance {
                    previousDiagonal = diagonal + 1
                } else if diagonal == distance {
                    previousDiagonal = diagonal - 1
                } else {
                    let deletion = previousValue(previous, distance: distance - 1, diagonal: diagonal - 1)
                    let insertion = previousValue(previous, distance: distance - 1, diagonal: diagonal + 1)
                    previousDiagonal = deletion < insertion ? diagonal + 1 : diagonal - 1
                }
                let previousX = previousValue(previous, distance: distance - 1, diagonal: previousDiagonal)
                let previousY = previousX - previousDiagonal

                while x > previousX, y > previousY {
                    if backtrackSteps.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
                    backtrackSteps += 1
                    x -= 1
                    y -= 1
                    reversed.append(.equal(left: leftRange.lowerBound + x, right: rightRange.lowerBound + y))
                }
                if x == previousX {
                    y -= 1
                    reversed.append(.insert(right: rightRange.lowerBound + y))
                } else {
                    x -= 1
                    reversed.append(.delete(left: leftRange.lowerBound + x))
                }
            }
        }
        while x > 0, y > 0 {
            if backtrackSteps.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
            backtrackSteps += 1
            x -= 1
            y -= 1
            reversed.append(.equal(left: leftRange.lowerBound + x, right: rightRange.lowerBound + y))
        }
        try checkCancellation(isCancelled)
        return reversed.reversed()
    }

    static func alignedRows(
        edits: [Edit],
        left: LineSource,
        right: LineSource,
        maximumRows: Int,
        isCancelled: @Sendable () -> Bool
    ) throws(OpenDocumentComparison.Error) -> [Row]? {
        try checkCancellation(isCancelled)
        var rows: [Row] = []
        var index = 0
        while index < edits.count {
            if index.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
            if case .equal(let leftIndex, let rightIndex) = edits[index] {
                guard rows.count < maximumRows else { return nil }
                rows.append(Row(
                    left: left.reference(at: leftIndex),
                    right: right.reference(at: rightIndex),
                    kind: .unchanged
                ))
                index += 1
                continue
            }

            var deleted: [Int] = []
            var inserted: [Int] = []
            while index < edits.count {
                if index.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
                switch edits[index] {
                case .equal:
                    break
                case .delete(let leftIndex):
                    deleted.append(leftIndex)
                    index += 1
                    continue
                case .insert(let rightIndex):
                    inserted.append(rightIndex)
                    index += 1
                    continue
                }
                break
            }
            guard try appendChangedRows(
                deleted: deleted,
                inserted: inserted,
                left: left,
                right: right,
                maximumRows: maximumRows,
                isCancelled: isCancelled,
                to: &rows
            ) else { return nil }
        }
        return rows
    }

    static func appendChangedRows<Deleted: RandomAccessCollection, Inserted: RandomAccessCollection>(
        deleted: Deleted,
        inserted: Inserted,
        left: LineSource,
        right: LineSource,
        maximumRows: Int,
        isCancelled: @Sendable () -> Bool,
        to rows: inout [Row]
    ) throws(OpenDocumentComparison.Error) -> Bool where Deleted.Element == Int, Inserted.Element == Int {
        try checkCancellation(isCancelled)
        let paired = min(deleted.count, inserted.count)
        let addedRows = max(deleted.count, inserted.count)
        guard rows.count <= maximumRows - addedRows else { return false }
        for offset in 0..<paired {
            if offset.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
            let leftIndex = deleted[deleted.index(deleted.startIndex, offsetBy: offset)]
            let rightIndex = inserted[inserted.index(inserted.startIndex, offsetBy: offset)]
            rows.append(Row(
                left: left.reference(at: leftIndex),
                right: right.reference(at: rightIndex),
                kind: .replaced
            ))
        }
        for (offset, leftIndex) in deleted.dropFirst(paired).enumerated() {
            if offset.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
            rows.append(Row(left: left.reference(at: leftIndex), right: nil, kind: .deleted))
        }
        for (offset, rightIndex) in inserted.dropFirst(paired).enumerated() {
            if offset.isMultiple(of: 1_024) { try checkCancellation(isCancelled) }
            rows.append(Row(left: nil, right: right.reference(at: rightIndex), kind: .inserted))
        }
        return true
    }
}
