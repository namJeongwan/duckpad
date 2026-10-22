#pragma once
#include <cstdint>
namespace Scintilla { class ILexer5; }
constexpr int DPLogForegroundIndicator = 11;
constexpr int DPLogBackgroundIndicator = 7;
constexpr int DPLogEscapeStyle = 15;
constexpr int DPLogStyleBase = 64;
constexpr int DPLogRoleCount = 10;
constexpr int DPLogInvalidateOperation = 0x44504C49;
constexpr int DPLogStatisticsOperation = 0x44504C53;
struct DPLogStatistics { uint64_t styledBytes = 0; uint64_t maximumSliceMicroseconds = 0; };
Scintilla::ILexer5 *DPCreateLogLexer();
