#include <stdint.h>

typedef enum DPICURegexStatus {
    DPICURegexStatusOK = 0,
    DPICURegexStatusInvalidPattern = 1,
    DPICURegexStatusTimeLimit = 2,
    DPICURegexStatusStackLimit = 3,
    DPICURegexStatusTooManyCaptures = 4,
    DPICURegexStatusOutOfMemory = 5,
    DPICURegexStatusFailure = 6,
} DPICURegexStatus;

typedef struct DPICURegexResult {
    DPICURegexStatus status;
    int32_t matchCount;
    int32_t captureCount;
    int32_t *ranges;
} DPICURegexResult;

DPICURegexResult dp_icu_regex_find_all(
    const uint16_t *pattern, int32_t patternLength,
    const uint16_t *text, int32_t textLength,
    int32_t regionStart, int32_t regionLimit,
    uint32_t flags, int32_t timeLimitMilliseconds,
    int32_t stackLimitBytes, int32_t maximumMatches,
    int32_t maximumCaptures);
void dp_icu_regex_result_free(DPICURegexResult result);
