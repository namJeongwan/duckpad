import AppKit

public struct TabFlowLayoutResult: Equatable, Sendable {
    public let frames: [CGRect]
    public let rowIndices: [Int]
    public let rowCount: Int
    public let contentHeight: CGFloat

    public init(frames: [CGRect], rowIndices: [Int], rowCount: Int, contentHeight: CGFloat) {
        self.frames = frames
        self.rowIndices = rowIndices
        self.rowCount = rowCount
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
        rowHeight: CGFloat = 34,
        horizontalSpacing: CGFloat = 4,
        verticalSpacing: CGFloat = 4,
        insets: NSEdgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6),
        minimumItemWidth: CGFloat = 96,
        maximumItemWidth: CGFloat = 220
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
                contentHeight: insets.top + insets.bottom
            )
        }
        let usableWidth = max(minimumItemWidth, containerWidth - insets.left - insets.right)
        var x = insets.left
        var y = insets.top
        var frames: [CGRect] = []
        var rowIndices: [Int] = []
        var row = 0
        for proposedWidth in itemWidths {
            let width = min(max(proposedWidth, minimumItemWidth), min(maximumItemWidth, usableWidth))
            if x > insets.left, x + width > insets.left + usableWidth {
                x = insets.left
                y += rowHeight + verticalSpacing
                row += 1
            }
            frames.append(CGRect(x: x, y: y, width: width, height: rowHeight))
            rowIndices.append(row)
            x += width + horizontalSpacing
        }
        return TabFlowLayoutResult(
            frames: frames,
            rowIndices: rowIndices,
            rowCount: row + 1,
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
        minimumHeight: CGFloat = 42
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
    public var itemWidths: [CGFloat] = [] {
        didSet { invalidateLayout() }
    }
    public var engine = TabFlowLayoutEngine() {
        didSet { invalidateLayout() }
    }
    public var onContentHeightChange: ((CGFloat) -> Void)?

    private var attributes: [NSCollectionViewLayoutAttributes] = []
    private var calculatedSize = NSSize(width: 0, height: 42)

    public override func prepare() {
        super.prepare()
        guard let collectionView else { return }
        let result = engine.layout(itemWidths: itemWidths, containerWidth: collectionView.bounds.width)
        attributes = result.frames.enumerated().map { index, frame in
            let item = NSCollectionViewLayoutAttributes(forItemWith: IndexPath(item: index, section: 0))
            item.frame = frame
            return item
        }
        let newSize = NSSize(width: collectionView.bounds.width, height: result.contentHeight)
        if calculatedSize != newSize {
            calculatedSize = newSize
            onContentHeightChange?(result.contentHeight)
        }
    }

    public override var collectionViewContentSize: NSSize { calculatedSize }

    public override func layoutAttributesForElements(in rect: NSRect) -> [NSCollectionViewLayoutAttributes] {
        attributes.filter { $0.frame.intersects(rect) }
    }

    public override func layoutAttributesForItem(at indexPath: IndexPath) -> NSCollectionViewLayoutAttributes? {
        attributes.indices.contains(indexPath.item) ? attributes[indexPath.item] : nil
    }

    public func row(forItemAt index: Int) -> Int? {
        guard itemWidths.indices.contains(index),
              let collectionView else {
            return nil
        }
        return engine.layout(
            itemWidths: itemWidths,
            containerWidth: collectionView.bounds.width
        ).rowIndices[index]
    }

    public override func shouldInvalidateLayout(forBoundsChange newBounds: NSRect) -> Bool {
        newBounds.width != collectionView?.bounds.width
    }
}
