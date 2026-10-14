// Duckpad: sparse, byte-exact UTF-8 coordinate checkpoints. Updates repair the
// edited span and its scalar-boundary neighbours, then shift unchanged points.
#ifndef UTF8POSITIONINDEX_H
#define UTF8POSITIONINDEX_H

namespace Scintilla::Internal {

class UTF8PositionIndex {
public:
	struct Point {
		Sci::Position byte = 0, utf16 = 0, characters = 0, column = 0;
		Sci::Position lastTab = -1;
	};
private:
	SplitView text;
	int tabWidth = 4;
	std::vector<Point> points;
	static constexpr Sci::Position spacing = 4096;
	void Advance(Point &point) const noexcept {
		const size_t byte = point.byte;
		const size_t available = byte < text.length1 ? text.length1 - byte : text.length - byte;
		const char *data = byte < text.length1 ? text.segment1 + byte : text.segment2 + byte;
		char crossing[4];
		int width;
		if (available >= 4 || byte + available == text.length) {
			width = UTF8DrawBytes(data, available);
		} else {
			const size_t count = std::min<size_t>(4, text.length - byte);
			for (size_t i = 0; i < count; ++i) crossing[i] = text.CharAt(byte + i);
			width = UTF8DrawBytes(crossing, count);
		}
		if (*data == '\t') {
			point.lastTab = point.byte;
			point.column = (point.column / tabWidth + 1) * tabWidth;
		} else {
			++point.column;
		}
		point.byte += width;
		point.utf16 += width == 4 ? 2 : 1;
		++point.characters;
	}
	std::vector<Point> Scan(Point begin, Sci::Position end) const {
		std::vector<Point> result;
		Sci::Position last = begin.byte;
		while (begin.byte < end) {
			Advance(begin);
			if (begin.byte - last >= spacing || begin.byte == end) {
				result.push_back(begin);
				last = begin.byte;
			}
		}
		return result;
	}
public:
	explicit UTF8PositionIndex(SplitView value, int width = 4) : text(value), tabWidth(width), points(1) {
		const auto rest = Scan({}, text.length);
		points.insert(points.end(), rest.begin(), rest.end());
	}
	int TabWidth() const noexcept { return tabWidth; }
	void SetView(SplitView value) noexcept { text = value; }
	void Replace(Sci::Position position, Sci::Position removed, Sci::Position inserted, SplitView value) {
		const auto before = [](const Point &point, Sci::Position byte) { return point.byte < byte; };
		// Include up to three preceding bytes and four following bytes, because
		// arbitrary byte edits can form or split a UTF-8 scalar across the splice.
		auto first = std::lower_bound(points.begin(), points.end(), std::max<Sci::Position>(0, position - 3), before);
		if (first != points.begin()) --first;
		auto last = std::lower_bound(points.begin(), points.end(), position + removed + 4, before);
		if (last == points.end()) --last;
		const size_t firstIndex = first - points.begin(), lastIndex = last - points.begin();
		const Point oldEnd = *last;
		const Sci::Position delta = inserted - removed;
		text = value;
		const auto changed = Scan(*first, oldEnd.byte + delta);
		const Point newEnd = changed.empty() ? *first : changed.back();
		const Sci::Position characterDelta = newEnd.characters - oldEnd.characters;
		const Sci::Position columnDelta = newEnd.column - oldEnd.column;
		Sci::Position columnDeltaAfterTab = columnDelta;
		// A tab absorbs an alignment change. Locate only the checkpoint block
		// containing the first unchanged tab, never scan a tab-free suffix.
		auto tabPoint = std::lower_bound(points.begin() + lastIndex + 1, points.end(), oldEnd.byte,
			[](const Point &point, Sci::Position byte) { return point.lastTab < byte; });
		if (tabPoint != points.end()) {
			Point beforeTab = *(tabPoint - 1);
			beforeTab.byte += delta;
			beforeTab.characters += characterDelta;
			beforeTab.column += columnDelta;
			while (text.CharAt(beforeTab.byte) != '\t') Advance(beforeTab);
			const Sci::Position distance = beforeTab.characters - newEnd.characters;
			columnDeltaAfterTab = ((newEnd.column + distance) / tabWidth -
				(oldEnd.column + distance) / tabWidth) * tabWidth;
		}
		for (size_t i = lastIndex + 1; i < points.size(); ++i) {
			const bool afterTab = points[i].lastTab >= oldEnd.byte;
			points[i].column += afterTab ? columnDeltaAfterTab : columnDelta;
			points[i].lastTab = afterTab ? points[i].lastTab + delta : newEnd.lastTab;
			points[i].byte += delta;
			points[i].utf16 += newEnd.utf16 - oldEnd.utf16;
			points[i].characters += characterDelta;
		}
		points.erase(points.begin() + firstIndex + 1, points.begin() + lastIndex + 1);
		points.insert(points.begin() + firstIndex + 1, changed.begin(), changed.end());
	}
	Point AtByte(Sci::Position byte) const noexcept {
		auto it = std::upper_bound(points.begin(), points.end(), byte,
			[](Sci::Position value, const Point &point) { return value < point.byte; });
		Point point = *--it;
		while (point.byte < byte) {
			Point next = point;
			Advance(next);
			if (next.byte > byte) break;
			point = next;
		}
		return point;
	}
	Sci::Position Column(Sci::Position start, Sci::Position end) const noexcept {
		const Point from = AtByte(start), to = AtByte(end);
		auto block = std::lower_bound(points.begin(), points.end(), start,
			[](const Point &point, Sci::Position byte) { return point.lastTab < byte; });
		if (block == points.end()) return to.characters - from.characters;
		Sci::Position tab = std::max(start, (block - 1)->byte);
		while (tab < end && text.CharAt(tab) != '\t') ++tab;
		if (tab >= end) return to.characters - from.characters;
		const Sci::Position beforeTab = AtByte(tab).characters - from.characters;
		return to.column - ((from.column + beforeTab) / tabWidth - beforeTab / tabWidth) * tabWidth;
	}

	Sci::Position AtUTF16(Sci::Position character) const noexcept {
		if (character < 0 || character > points.back().utf16) return Sci::invalidPosition;
		auto it = std::upper_bound(points.begin(), points.end(), character,
			[](Sci::Position value, const Point &point) { return value < point.utf16; });
		Point point = *--it;
		while (point.utf16 < character) Advance(point);
		return point.utf16 == character ? point.byte : Sci::invalidPosition;
	}
};

}
#endif
