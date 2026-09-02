#include "DuckpadICUBridge.h"
#include <stdlib.h>
#include <unicode/uregex.h>

static DPICURegexStatus map_status(UErrorCode status) {
    if (status == U_REGEX_TIME_OUT) return DPICURegexStatusTimeLimit;
    if (status == U_REGEX_STACK_OVERFLOW) return DPICURegexStatusStackLimit;
    if (status >= U_REGEX_INTERNAL_ERROR && status <= U_REGEX_STOPPED_BY_CALLER) {
        return DPICURegexStatusInvalidPattern;
    }
    return DPICURegexStatusFailure;
}

DPICURegexResult dp_icu_regex_find_all(
    const uint16_t *pattern, int32_t patternLength,
    const uint16_t *text, int32_t textLength,
    int32_t regionStart, int32_t regionLimit,
    uint32_t flags, int32_t timeLimitMilliseconds,
    int32_t stackLimitBytes, int32_t maximumMatches,
    int32_t maximumCaptures) {
    DPICURegexResult output = { DPICURegexStatusOK, 0, 0, NULL };
    UErrorCode status = U_ZERO_ERROR;
    UParseError parseError;
    URegularExpression *expression = uregex_open(
        (const UChar *)pattern, patternLength, flags, &parseError, &status);
    if (U_FAILURE(status) || expression == NULL) {
        output.status = map_status(status);
        return output;
    }
    uregex_setTimeLimit(expression, timeLimitMilliseconds, &status);
    uregex_setStackLimit(expression, stackLimitBytes, &status);
    uregex_setText(expression, (const UChar *)text, textLength, &status);
    uregex_setRegion(expression, regionStart, regionLimit, &status);
    // Ranges constrain enumeration, not ^/$ or lookaround semantics. Keeping
    // document anchoring and transparent context also makes wrapped edge
    // searches agree with full-document ICU search.
    uregex_useAnchoringBounds(expression, 0, &status);
    uregex_useTransparentBounds(expression, 1, &status);
    int32_t captures = uregex_groupCount(expression, &status);
    if (U_FAILURE(status)) {
        output.status = map_status(status);
        uregex_close(expression);
        return output;
    }
    if (captures > maximumCaptures) {
        output.status = DPICURegexStatusTooManyCaptures;
        uregex_close(expression);
        return output;
    }
    const int edgeBackward = maximumMatches == -1;
    const int32_t storageMatches = edgeBackward ? 1 : maximumMatches;
    const int64_t slots = (int64_t)storageMatches * (captures + 1) * 2;
    if (slots <= 0 || slots > INT32_MAX) {
        output.status = DPICURegexStatusOutOfMemory;
        uregex_close(expression);
        return output;
    }
    output.ranges = (int32_t *)calloc((size_t)slots, sizeof(int32_t));
    if (output.ranges == NULL) {
        output.status = DPICURegexStatusOutOfMemory;
        uregex_close(expression);
        return output;
    }
    output.captureCount = captures;
    while (1) {
        if (!edgeBackward && output.matchCount >= maximumMatches) break;
        if (!uregex_findNext(expression, &status)) break;
        if (U_FAILURE(status)) break;
        int32_t *matchRanges = output.ranges
            + (edgeBackward ? 0 : output.matchCount) * (captures + 1) * 2;
        for (int32_t group = 0; group <= captures; group++) {
            matchRanges[group * 2] = uregex_start(expression, group, &status);
            matchRanges[group * 2 + 1] = uregex_end(expression, group, &status);
            if (U_FAILURE(status)) break;
        }
        if (U_FAILURE(status)) break;
        if (edgeBackward) output.matchCount = 1;
        else output.matchCount += 1;
    }
    if (U_FAILURE(status)) output.status = map_status(status);
    uregex_close(expression);
    return output;
}

void dp_icu_regex_result_free(DPICURegexResult result) {
    free(result.ranges);
}
