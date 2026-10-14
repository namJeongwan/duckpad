// Duckpad: preserve unchanged lexical regions in a complete, single-line JSON.
// Text equality is verified byte-for-byte; hashes are never used for correctness.
#ifndef JSONLONGLINECACHE_H
#define JSONLONGLINECACHE_H

#include <algorithm>
#include <cstring>
#include <limits>
#include <string>
#include <vector>

class JSONLongLineCache {
	Scintilla::IDocument *document = nullptr;
	std::string text;
	std::string pending;
	struct Brace { Sci_Position position; int delta; };
	std::vector<Brace> braces;
	int balance = 0;
	bool foldingValid = false;
	Sci_Position lexStart = 0;
	Sci_Position lexEnd = 0;
	Sci_Position foldScanEnd = 0;
	Sci_Position sizeChange = 0;
	bool reusedSuffix = false;
	bool hadError = false;
	bool saveSnapshot = false;
	std::string stableText;
	std::vector<char> stableStyles;
	std::vector<Brace> stableBraces;
	int stableBalance = 0;
public:
	bool restored = false;
	Sci_PositionU reuseAfter = std::numeric_limits<Sci_PositionU>::max();

	void Clear() {
		document = nullptr;
		stableText.clear();
		stableStyles.clear();
		stableBraces.clear();
		hadError = false;
		restored = false;
		braces.clear();
		foldingValid = false;
		text.clear();
		pending.clear();
		reuseAfter = std::numeric_limits<Sci_PositionU>::max();
	}

	Sci_PositionU Prepare(Scintilla::IDocument *doc, Sci_PositionU start, Sci_Position length) {
		reuseAfter = std::numeric_limits<Sci_PositionU>::max();
		restored = false;
		saveSnapshot = false;
		const Sci_Position size = doc->Length();
		if (start != 0 || length != size || size < 65536 || size > 32 * 1024 * 1024 || doc->LineFromPosition(size) != 0) {
			Clear();
			return start;
		}
		pending.resize(size);
		doc->GetCharRange(pending.data(), 0, size);
		// Keep one known error-free result across temporarily invalid typing.
		// Deleting the last invalid character can otherwise re-lex all 9 MB.
		if (document == doc && !stableStyles.empty() && pending == stableText) {
			doc->StartStyling(0);
			doc->SetStyles(size, stableStyles.data());
			text.swap(pending);
			pending.clear();
			braces = stableBraces;
			balance = stableBalance;
			foldingValid = true;
			hadError = false;
			restored = true;
			return 0;
		}
		if (document == doc && !text.empty() && text != pending) {
			// Coarse boundaries are intentional: lex a little extra, while comparing
			// megabytes with the platform's vectorized memcmp implementation.
			constexpr size_t block = 4096;
			const size_t common = std::min(text.size(), pending.size());
			size_t prefix = 0;
			while (prefix + block <= common &&
				std::memcmp(text.data() + prefix, pending.data() + prefix, block) == 0)
				prefix += block;
			size_t suffix = 0;
			while (suffix + block <= common - prefix &&
				std::memcmp(text.data() + text.size() - suffix - block,
					pending.data() + pending.size() - suffix - block, block) == 0)
				suffix += block;
			// AtPropertyName looks ahead at most 100 + 50 bytes. Restart before
			// that dependency, at a known structural token outside any string.
			start = prefix > 160 ? prefix - 160 : 0;
			while (start && doc->StyleAt(start) != SCE_JSON_OPERATOR) --start;
			reuseAfter = pending.size() - suffix + 160;
		}
		if (document != doc) foldingValid = false;
		document = doc;
		lexStart = start;
		return start;
	}

	void Complete(Scintilla::IDocument *doc, Sci_Position end, bool reuse, bool errors, Sci_Position structuralEnd) {
		lexEnd = std::min<Sci_Position>(end, pending.size());
		foldScanEnd = std::min(lexEnd, structuralEnd);
		sizeChange = static_cast<Sci_Position>(pending.size()) - static_cast<Sci_Position>(text.size());
		reusedSuffix = reuse;
		hadError = errors || (reuse && hadError);
		if (document && !hadError) {
			const bool incremental = stableText == text && stableStyles.size() == text.size();
			const Sci_Position from = incremental ? lexStart : 0;
			const Sci_Position to = incremental && reuse ? lexEnd : pending.size();
			if (incremental && sizeChange > 0)
				stableStyles.insert(stableStyles.begin() + from, sizeChange, 0);
			else if (incremental && sizeChange < 0)
				stableStyles.erase(stableStyles.begin() + from, stableStyles.begin() + from - sizeChange);
			else stableStyles.resize(pending.size());
			for (Sci_Position i = from; i < to; ++i) stableStyles[i] = doc->StyleAt(i);
			stableText = pending;
			saveSnapshot = true;
		}
		text.swap(pending);
		pending.clear();
	}

	int FoldBalance(Scintilla::IDocument *doc) {
		if (restored) return balance;
		if (!foldingValid) { braces.clear(); balance = 0; lexStart = 0; lexEnd = text.size(); reusedSuffix = false; }
		const Sci_Position oldEnd = reusedSuffix ? lexEnd - sizeChange : std::numeric_limits<Sci_Position>::max();
		auto before = [](const Brace &brace, Sci_Position position) { return brace.position < position; };
		const auto first = std::lower_bound(braces.begin(), braces.end(), lexStart, before);
		const auto last = std::lower_bound(first, braces.end(), oldEnd, before);
		for (auto it = first; it != last; ++it) balance -= it->delta;
		const size_t index = first - braces.begin();
		auto suffix = braces.erase(first, last);
		for (auto it = suffix; it != braces.end(); ++it) it->position += sizeChange;
		std::vector<Brace> changed;
		// The lexer proves that a single-line error tail has no operator styles.
		// Remove its old braces above, but do not scan that tail for new ones.
		for (Sci_Position i = lexStart; i < foldScanEnd; ++i) {
			const char ch = text[i];
			if ((ch == '{' || ch == '[' || ch == '}' || ch == ']') && doc->StyleAt(i) == SCE_JSON_OPERATOR) {
				const int delta = (ch == '{' || ch == '[') ? 1 : -1;
				changed.push_back({i, delta});
				balance += delta;
			}
		}
		braces.insert(braces.begin() + index, changed.begin(), changed.end());
		foldingValid = true;
		if (saveSnapshot) { stableBraces = braces; stableBalance = balance; }
		return balance;
	}

	const std::string *FullText(Scintilla::IDocument *doc, Sci_PositionU start, Sci_Position length) const {
		return document == doc && start == 0 && length == static_cast<Sci_Position>(text.size()) ? &text : nullptr;
	}
};
#endif
