// Adapted from CodeEditSourceEditor/CodeSuggestion/TableView/CodeSuggestionLabelView.swift.
// Copyright (c) 2022 CodeEdit. MIT license; see LICENSE.md.
import AppKit

final class CodeSuggestionLabelView: NSTableCellView {
    let nameLabel = NSTextField(labelWithString: "")
    let detailLabel = NSTextField(labelWithString: "")
    private let symbolView = NSImageView()
    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [symbolView, nameLabel, detailLabel] { view.translatesAutoresizingMaskIntoConstraints = false; addSubview(view) }
        nameLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingHead
        detailLabel.textColor = .secondaryLabelColor
        nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            symbolView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            symbolView.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 12), symbolView.heightAnchor.constraint(equalToConstant: 12),
            nameLabel.leadingAnchor.constraint(equalTo: symbolView.trailingAnchor, constant: 6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 12),
            detailLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            detailLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, multiplier: 0.42)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func apply(_ item: CodeSuggestionItem, font: NSFont, theme: CodeSuggestionTheme) {
        symbolView.image = NSImage(systemSymbolName: item.symbol, accessibilityDescription: nil)
        symbolView.contentTintColor = item.color
        let label = NSMutableAttributedString(string: item.label, attributes: [.font: font, .foregroundColor: theme.foreground])
        for range in item.matchedRanges where range.location >= 0 && NSMaxRange(range) <= label.length {
            label.addAttributes([.font: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask),
                                 .foregroundColor: theme.accent], range: range)
        }
        nameLabel.attributedStringValue = label
        detailLabel.textColor = theme.secondary
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.stringValue = item.detail
        toolTip = [item.label, item.detail].filter { !$0.isEmpty }.joined(separator: " — ")
        setAccessibilityLabel(toolTip)
    }
}
