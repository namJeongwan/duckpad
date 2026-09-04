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

    public init(
        rowHeight: CGFloat = 28,
        horizontalSpacing: CGFloat = 2,
        verticalSpacing: CGFloat = 2,
        insets: NSEdgeInsets = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6),
        minimumItemWidth: CGFloat = 88,
        maximumItemWidth: CGFloat = .greatestFiniteMagnitude
    ) {
        self.rowHeight = rowHeight
        self.horizontalSpacing = horizontalSpacing
        self.verticalSpacing = verticalSpacing
        self.insets = insets
        self.minimumItemWidth = minimumItemWidth
        self.maximumItemWidth = maximumItemWidth
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
        var x = insets.left
        var y = insets.top
        var frames: [CGRect] = []
        var rowIndices: [Int] = []
        var row = 0
        var maximumFrameX: CGFloat = 0
        for proposedWidth in itemWidths {
            let width = min(max(proposedWidth, minimumItemWidth), maximumItemWidth)
            if x > insets.left, x + width > insets.left + usableWidth {
                x = insets.left
                y += rowHeight + verticalSpacing
                row += 1
            }
            let frame = CGRect(x: x, y: y, width: width, height: rowHeight)
            frames.append(frame)
            rowIndices.append(row)
            maximumFrameX = max(maximumFrameX, frame.maxX)
            x += width + horizontalSpacing
        }
        return TabFlowLayoutResult(
            frames: frames,
            rowIndices: rowIndices,
            rowCount: row + 1,
            contentWidth: max(containerWidth, maximumFrameX + insets.right),
            contentHeight: y + rowHeight + insets.bottom
        )
    }
}

public struct TabStripViewportPolicy: Equatable, Sendable {
    public var maximumRows: Int
    public var maximumWorkspaceFraction: CGFloat
    public var minimumHeight: CGFloat

    public init(
        maximumRows: Int = 4,
        maximumWorkspaceFraction: CGFloat = 0.34,
        minimumHeight: CGFloat = 34
    ) {
        self.maximumRows = maximumRows
        self.maximumWorkspaceFraction = maximumWorkspaceFraction
        self.minimumHeight = minimumHeight
    }

    public func height(
        contentHeight: CGFloat,
        workspaceHeight: CGFloat,
        engine: TabFlowLayoutEngine
    ) -> CGFloat {
        let rows = max(1, maximumRows)
        let rowCap = engine.insets.top + engine.insets.bottom
            + CGFloat(rows) * engine.rowHeight
            + CGFloat(rows - 1) * engine.verticalSpacing
        let fractionCap = max(minimumHeight, workspaceHeight * maximumWorkspaceFraction)
        return min(contentHeight, max(minimumHeight, min(rowCap, fractionCap)))
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
    private var calculatedSize = NSSize(width: 0, height: 34)
    private var widthsVersion: UInt64 = 0
    private var preparedWidthsVersion: UInt64 = .max
    private var preparedWidth: CGFloat = -.greatestFiniteMagnitude
    public private(set) var layoutGeneration: UInt64 = 0
    public private(set) var lastElementsQueryVisitedRows = 0
    public private(set) var lastElementsQueryInspectedItems = 0
    public var rowCount: Int { cachedRowCount }

    public override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let width = viewportWidth > 0 ? viewportWidth : collectionView.bounds.width
        guard preparedWidthsVersion != widthsVersion || preparedWidth != width else { return }
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
        layoutGeneration &+= 1
        let newSize = NSSize(width: result.contentWidth, height: result.contentHeight)
        if calculatedSize != newSize {
            calculatedSize = newSize
            onContentSizeChange?(newSize)
        }
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
            if rows[middle].maxY < rect.minY { lower = middle + 1 }
            else { upper = middle }
        }
        var visible: [NSCollectionViewLayoutAttributes] = []
        var rowIndex = lower
        while rowIndex < rows.count, rows[rowIndex].minY <= rect.maxY {
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
