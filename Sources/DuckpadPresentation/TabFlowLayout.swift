import AppKit

/// Converts AppKit's pre-removal `.before` insertion index to the Domain's
/// final-index move contract. This makes every drag direction, including a
/// drop after the last item, deterministic and directly testable.
public enum TabDropDestination {
    public static func finalIndex(sourceIndex: Int, insertionIndex: Int, itemCount: Int) -> Int? {
        guard itemCount > 0,
              (0..<itemCount).contains(sourceIndex),
              (0...itemCount).contains(insertionIndex) else { return nil }
        let adjusted = sourceIndex < insertionIndex ? insertionIndex - 1 : insertionIndex
        return min(max(adjusted, 0), itemCount - 1)
    }
}

public struct TabFlowLayoutResult: Equatable, Sendable {
    public let frames: [CGRect]
    public let rowIndices: [Int]
    public let rowCount: Int
    public let contentWidth: CGFloat
    public let contentHeight: CGFloat

    public init(
        frames: [CGRect],
        rowIndices: [Int],
        rowCount: Int,
        contentWidth: CGFloat,
        contentHeight: CGFloat
    ) {
        self.frames = frames
        self.rowIndices = rowIndices
        self.rowCount = rowCount
        self.contentWidth = contentWidth
        self.contentHeight = contentHeight
    }
}

public struct TabFlowLayoutEngine: Sendable {
    public var rowHeight: CGFloat
    public var horizontalSpacing: CGFloat
    public var verticalSpacing: CGFloat
    public var insets: NSEdgeInsets
    public var minimumItemWidth: CGFloat
    public var maximumItemWidth: CGFloat
    public var backingScale: CGFloat

    public init(
        rowHeight: CGFloat = 27,
        horizontalSpacing: CGFloat = 0,
        verticalSpacing: CGFloat = 0,
        insets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0),
        minimumItemWidth: CGFloat = 76,
        maximumItemWidth: CGFloat = .greatestFiniteMagnitude,
        backingScale: CGFloat = 2
    ) {
        self.rowHeight = rowHeight
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.insets = insets
        self.minimumItemWidth = minimumItemWidth
        self.maximumItemWidth = maximumItemWidth
        self.backingScale = backingScale
    }

    public func layout(itemWidths: [CGFloat], containerWidth: CGFloat) -> TabFlowLayoutResult {
        guard !itemWidths.isEmpty else {
            return TabFlowLayoutResult(
                frames: [],
                rowIndices: [],
                rowCount: 0,
                contentWidth: max(0, containerWidth),
                contentHeight: insets.top + insets.bottom
            )
        }
        let usableWidth = max(minimumItemWidth, containerWidth - insets.left - insets.right)
        // A proposed width includes the complete rendered filename. It is an
        // inviolable minimum even when a caller still supplies the legacy
        // maximumItemWidth configuration.
        let boundedWidths = itemWidths.map { max($0, minimumItemWidth) }
        func naturalWidth(of range: Range<Int>) -> CGFloat {
            range.reduce(CGFloat(0)) { $0 + boundedWidths[$1] }
                + CGFloat(max(0, range.count - 1)) * horizontalSpacing
        }

        let totalNaturalWidth = naturalWidth(of: boundedWidths.indices)
        var rowRanges: [Range<Int>] = []
        if totalNaturalWidth <= usableWidth || boundedWidths.count == 1 {
            rowRanges = [boundedWidths.indices]
        } else {
            // A greedy pass gives the minimum ordered row count without
            // dividing by a possibly zero usable width. A lone oversized
            // title is valid by design.
            var greedyRanges: [Range<Int>] = []
            var rowStart = 0
            var rowWidth: CGFloat = 0
            for (index, width) in boundedWidths.enumerated() {
                let candidateWidth = rowWidth == 0 ? width : rowWidth + horizontalSpacing + width
                if index > rowStart, candidateWidth > usableWidth {
                    greedyRanges.append(rowStart..<index)
                    rowStart = index
                    rowWidth = width
                } else {
                    rowWidth = candidateWidth
                }
            }
            greedyRanges.append(rowStart..<boundedWidths.count)

            let rowCount = greedyRanges.count
            let baseItemCount = boundedWidths.count / rowCount
            let fullerRowCount = boundedWidths.count % rowCount
            var balancedRanges: [Range<Int>] = []
            var balancedStart = 0
            for row in 0..<rowCount {
                let count = baseItemCount + (row < fullerRowCount ? 1 : 0)
                let range = balancedStart..<(balancedStart + count)
                balancedRanges.append(range)
                balancedStart += count
            }
            // Variable-width titles can make the fuller-first candidate
            // impossible even though the minimum ordered rows are valid.
            // Keep that minimum contiguous packing in this case.
            rowRanges = balancedRanges.allSatisfy {
                $0.count == 1 || naturalWidth(of: $0) <= usableWidth
            } ? balancedRanges : greedyRanges
        }

        var frames: [CGRect] = []
        var rowIndices: [Int] = []
        var maximumFrameX: CGFloat = 0
        for (row, range) in rowRanges.enumerated() {
            var x = insets.left
            let y = insets.top + CGFloat(row) * (rowHeight + verticalSpacing)
            let slack = rowRanges.count > 1
                ? max(0, usableWidth - naturalWidth(of: range))
                : 0
            let distributedSlack = slack / CGFloat(range.count)
            let pixelScale = max(1, backingScale)
            func pixelAligned(_ value: CGFloat) -> CGFloat {
                (value * pixelScale).rounded() / pixelScale
            }
            let justifiedRowEnd = pixelAligned(insets.left + usableWidth)
            var naturalPrefix: CGFloat = 0
            for (offset, index) in range.enumerated() {
                if offset > 0 { naturalPrefix += horizontalSpacing }
                naturalPrefix += boundedWidths[index]
                var width = boundedWidths[index] + distributedSlack
                if slack > 0 {
                    if offset == range.count - 1 {
                        width = justifiedRowEnd - x
                    } else {
                        let idealMaxX = insets.left + naturalPrefix
                            + distributedSlack * CGFloat(offset + 1)
                        width = pixelAligned(idealMaxX) - x
                    }
                }
                let frame = CGRect(x: x, y: y, width: width, height: rowHeight)
                frames.append(frame)
                rowIndices.append(row)
                maximumFrameX = max(maximumFrameX, frame.maxX)
                x += width + horizontalSpacing
            }
        }
        return TabFlowLayoutResult(
            frames: frames,
            rowIndices: rowIndices,
            rowCount: rowRanges.count,
            contentWidth: max(containerWidth, maximumFrameX + insets.right),
            contentHeight: insets.top + insets.bottom
                + CGFloat(rowRanges.count) * rowHeight
                + CGFloat(max(0, rowRanges.count - 1)) * verticalSpacing
        )
    }
}

@MainActor
public final class MultilineTabCollectionLayout: NSCollectionViewLayout {
    private struct RowCache {
        let itemRange: Range<Int>
        let minY: CGFloat
        let maxY: CGFloat
    }
    public var itemWidths: [CGFloat] = [] {
        didSet {
            guard itemWidths != oldValue else { return }
            widthsVersion &+= 1
            invalidateLayout()
        }
    }
    public var engine = TabFlowLayoutEngine() {
        didSet {
            widthsVersion &+= 1
            invalidateLayout()
        }
    }
    public var onContentSizeChange: ((NSSize) -> Void)?
    public var onLayoutRegenerated: (() -> Void)?
    public var viewportWidth: CGFloat = 0 {
        didSet {
            guard viewportWidth != oldValue else { return }
            invalidateLayout()
        }
    }

    private var attributes: [NSCollectionViewLayoutAttributes] = []
    private var rowIndices: [Int] = []
    private var rows: [RowCache] = []
    private var cachedRowCount = 0
    private var calculatedSize = NSSize(width: 0, height: 27)
    private var widthsVersion: UInt64 = 0
    private var preparedWidthsVersion: UInt64 = .max
    private var preparedWidth: CGFloat = -.greatestFiniteMagnitude
    private var preparedItemCount = -1
    public private(set) var layoutGeneration: UInt64 = 0
    public private(set) var lastElementsQueryVisitedRows = 0
    public private(set) var lastElementsQueryInspectedItems = 0
    public var rowCount: Int { cachedRowCount }

    public override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = viewportWidth > 0 ? viewportWidth : collectionView.bounds.width
        let hasDataSource = collectionView.dataSource != nil
        let itemCount = hasDataSource ? collectionView.numberOfItems(inSection: 0) : itemWidths.count
        guard !hasDataSource || itemWidths.count == itemCount else {
            // During a structural collection update, AppKit can prepare the
            // layout while its internal item count still reflects the old
            // data source. Keep the last coherent cache until both counts
            // agree, then the already-invalidated layout will prepare again.
            return
        }
        guard preparedWidthsVersion != widthsVersion
                || preparedWidth != width
                || preparedItemCount != itemCount else { return }
        let result = engine.layout(itemWidths: itemWidths, containerWidth: width)
        attributes = result.frames.enumerated().map { index, frame in
            let item = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
            item.frame = frame
            return item
        }
        rowIndices = result.rowIndices
        cachedRowCount = result.rowCount
        rows = Self.makeRows(frames: result.frames, rowIndices: result.rowIndices)
        preparedWidthsVersion = widthsVersion
        preparedWidth = width
        preparedItemCount = itemCount
        layoutGeneration &+= 1
        let newSize = NSSize(width: result.contentWidth, height: result.contentHeight)
        if calculatedSize != newSize {
            calculatedSize = newSize
            onContentSizeChange?(newSize)
        }
        onLayoutRegenerated?()
    }

    public override var collectionViewContentSize: NSSize { calculatedSize }

    public override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        lastElementsQueryVisitedRows = 0
        lastElementsQueryInspectedItems = 0
        guard !rows.isEmpty else { return [] }
        var lower = 0
        var upper = rows.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if rows[middle].maxY <= rect.minY { lower = middle + 1 }
            else { upper = middle }
        }
        var visible: [NSCollectionViewLayoutAttributes] = []
        var rowIndex = lower
        while rowIndex < rows.count, rows[rowIndex].minY < rect.maxY {
            let row = rows[rowIndex]
            lastElementsQueryVisitedRows += 1
            for itemIndex in row.itemRange {
                lastElementsQueryInspectedItems += 1
                let item = attributes[itemIndex]
                if item.frame.intersects(rect) { visible.append(item) }
            }
            rowIndex += 1
        }
        return visible
    }

    public override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }

    public func row(forItemAt index: Int) -> Int? {
        rowIndices.indices.contains(index) ? rowIndices[index] : nil
    }

    public func updateItemWidth(_ width: CGFloat, at index: Int) {
        guard itemWidths.indices.contains(index), itemWidths[index] != width else { return }
        itemWidths[index] = width
    }

    @discardableResult
    public func insertItemWidth(_ width: CGFloat, at index: Int) -> Bool {
        guard (0...itemWidths.count).contains(index) else { return false }
        itemWidths.insert(width, at: index)
        return true
    }

    public func destinationIndex(at point: NSPoint) -> Int {
        guard !attributes.isEmpty else { return 0 }
        if let containing = attributes.firstIndex(where: { $0.frame.contains(point) }) {
            return containing
        }
        let sameOrNextRow = attributes.enumerated().min { lhs, rhs in
            let lhsDistance = hypot(lhs.element.frame.midX - point.x, lhs.element.frame.midY - point.y)
            let rhsDistance = hypot(rhs.element.frame.midX - point.x, rhs.element.frame.midY - point.y)
            return lhsDistance < rhsDistance
        }
        return sameOrNextRow?.offset ?? attributes.count - 1
    }

    public override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }

    private static func makeRows(frames: [CGRect], rowIndices: [Int]) -> [RowCache] {
        guard !frames.isEmpty else { return [] }
        var result: [RowCache] = []
        var start = 0
        while start < frames.count {
            let row = rowIndices[start]
            var end = start + 1
            var minY = frames[start].minY
            var maxY = frames[start].maxY
            while end < frames.count, rowIndices[end] == row {
                minY = min(minY, frames[end].minY)
                maxY = max(maxY, frames[end].maxY)
                end += 1
            }
            result.append(RowCache(itemRange: start..<end, minY: minY, maxY: maxY))
            start = end
        }
        return result
    }
}
